import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

// Window motion engine — daemon-side animated setFrame.
//
// Split from Windows.swift so the scheduling core stays pure and headless-
// testable (precedent: Display.swift / DisplayDDC.swift). Three layers:
//
//   MotionMath    — easing curves + a critically-damped spring, pure math.
//   MotionPlanner — pure scheduler: registrations in, per-tick AX writes out.
//   WindowMotionEngine — the only impure part: subscribes a display-link
//                   clock per display while animations are live and hands
//                   the AX writes to per-app writer queues.
//
// Why daemon-side at all (vs. the JS rAF loop windowscape shipped): every
// animating window on a display is evaluated inside ONE display-link tick on
// ONE clock, so a multi-window tile pass moves in lockstep instead of staggering on
// per-window RPC round-trips. hs.window:setFrame(rect, duration) is the
// Hammerspoon precedent that sanctions the daemon owning this.
//
// The spring is the textbook critically-damped harmonic oscillator solved
// in closed form — implemented from the math, not ported (OmniWM, the
// behavioral reference for feel/stiffness, is GPL-2.0).

enum MotionEasing: String {
    case linear
    case easeOutCubic
    case spring
}

enum MotionMath {
    static func linear(_ t: Double) -> Double {
        min(1, max(0, t))
    }

    static func easeOutCubic(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        return 1 - pow(1 - c, 3)
    }

    /// Critically damped spring (mass 1, damping = critical). With β = √k:
    ///   x(t) = target + e^(−βt)·(x₀ + (βx₀ + v₀)·t),  x₀ = from − target
    /// and v(t) is its analytic derivative, so an interrupted spring can
    /// hand its instantaneous velocity to a replacement for continuous
    /// momentum. Stiffness 800 ≈ the "snappy but never bouncy" feel of the
    /// tiling-WM springs this is modeled on (settles a 500px move in ~0.35s).
    struct Spring {
        let from: Double
        let target: Double
        let initialVelocity: Double
        let stiffness: Double

        init(from: Double, target: Double, initialVelocity: Double, stiffness: Double = 800) {
            self.from = from
            self.target = target
            self.initialVelocity = initialVelocity
            self.stiffness = max(1, stiffness)
        }

        func value(at elapsed: Double) -> Double {
            let t = max(0, elapsed)
            let beta = stiffness.squareRoot()
            let x0 = from - target
            let b = beta * x0 + initialVelocity
            return target + exp(-beta * t) * (x0 + b * t)
        }

        func velocity(at elapsed: Double) -> Double {
            let t = max(0, elapsed)
            let beta = stiffness.squareRoot()
            let x0 = from - target
            let b = beta * x0 + initialVelocity
            return exp(-beta * t) * (b - beta * (x0 + b * t))
        }

        func isSettled(at elapsed: Double, epsilon: Double, velocityEpsilon: Double) -> Bool {
            abs(value(at: elapsed) - target) <= epsilon
                && abs(velocity(at: elapsed)) <= velocityEpsilon
        }
    }
}

/// Whether a setFrame request animates. A duration or a spring asks for
/// motion; the system Reduce Motion setting turns that into an instant write
/// unless the caller opted out (a stack whose motion carries meaning, or
/// that honors the setting itself).
enum MotionRouting {
    static func animates(duration: Double, easing: MotionEasing?,
                         reduceMotion: Bool, respectReduceMotion: Bool) -> Bool {
        guard duration > 0 || easing == .spring else { return false }
        return !(reduceMotion && respectReduceMotion)
    }
}

/// Which display's refresh drives a window's animation: the display
/// holding the target frame's center, else the one it overlaps most, else
/// none (the caller falls back to the all-displays link).
enum MotionClock {
    static func display(for target: CGRect,
                        displays: [(id: CGDirectDisplayID, bounds: CGRect)]) -> CGDirectDisplayID? {
        let center = CGPoint(x: target.midX, y: target.midY)
        if let hit = displays.first(where: { $0.bounds.contains(center) }) { return hit.id }
        var best: (id: CGDirectDisplayID, area: CGFloat)?
        for d in displays {
            let i = d.bounds.intersection(target)
            guard !i.isNull, i.width > 0, i.height > 0 else { continue }
            let area = i.width * i.height
            if best == nil || area > best!.area { best = (d.id, area) }
        }
        return best?.id
    }

    /// Active displays with their global top-left bounds (AX frame space).
    static func activeDisplays() -> [(id: CGDirectDisplayID, bounds: CGRect)] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { (id: $0, bounds: CGDisplayBounds($0)) }
    }
}

/// Which AX attribute a frame write sets first. Growing position-first
/// keeps the larger size from being clamped against the old origin (a
/// window near a screen edge); shrinking size-first keeps the move from
/// pushing the still-large window past an edge.
enum FrameWriteOrder: Equatable {
    case positionThenSize
    case sizeThenPosition

    static func pick(current: CGRect?, target: CGRect) -> FrameWriteOrder {
        guard let c = current else { return .sizeThenPosition }
        if target.width > c.width + 0.5 || target.height > c.height + 0.5 { return .positionThenSize }
        return .sizeThenPosition
    }

    /// After a settle's two setters: re-set the size only when the app
    /// reports a size other than the one written (it clamped the size set
    /// against the position it had at the time).
    static func needsSizeReassert(target: CGRect, readBack: CGSize?) -> Bool {
        guard let r = readBack else { return false }
        return abs(r.width - target.width) > 1 || abs(r.height - target.height) > 1
    }
}

/// Pure scheduling core. One registration per window (last-write-wins).
/// Start times are assigned by the FIRST tick a registration sees, not at
/// register time — every window registered between two ticks starts on the
/// same clock instant and evaluates identical `t` forever after. This is
/// the anti-stagger contract: N setFrame RPCs arriving in one runloop
/// burst animate as one choreographed pass.
struct MotionPlanner {
    struct FrameWrite: Equatable {
        let windowID: CGWindowID
        var frame: CGRect
        let isFinal: Bool
        // Axes that differ from the previous write. Final writes always
        // carry both — the settle frame must stick.
        var writeSize: Bool = true
        var writePosition: Bool = true
        var order: FrameWriteOrder = .sizeThenPosition

        /// This write at a size the app enforces. Mid-animation the size
        /// is left alone (position only), and a step that only changed the
        /// size has nothing left to write (nil). The settle frame still
        /// writes both axes, at the enforced size.
        func honoring(enforcedSize: CGSize?) -> FrameWrite? {
            guard let size = enforcedSize else { return self }
            var out = self
            out.frame.size = size
            if isFinal { return out }
            out.writeSize = false
            return out.writePosition ? out : nil
        }
    }

    struct Finished: Equatable {
        let windowID: CGWindowID
        let key: UInt64
        let settled: Bool
    }

    struct RegisterResult {
        let key: UInt64
        let superseded: Finished?
    }

    // Frame-space settle thresholds: half a pixel of displacement and a
    // velocity below perceptible drift. Sub-pixel precision is meaningless
    // for AX frames, which round to integers at write time.
    private static let settleEpsilon = 0.5
    private static let settleVelocityEpsilon = 5.0

    private struct Registration {
        let key: UInt64
        let to: CGRect
        let duration: Double
        let easing: MotionEasing
        var from: CGRect
        var startTime: Double?
        // Per-component (x, y, w, h) velocity handed over from a superseded
        // spring so the replacement continues the motion instead of
        // restarting from rest. Consumed when startTime is assigned.
        var seedVelocity: [Double]
        var springs: [MotionMath.Spring]?
        var lastWritten: CGRect
        // An intermediate write timed out (hung app): only the final frame
        // is written from here on.
        var stalled = false
    }

    private var active: [CGWindowID: Registration] = [:]
    private var nextKey: UInt64 = 1

    var isEmpty: Bool { active.isEmpty }

    func isAnimating(_ windowID: CGWindowID) -> Bool {
        active[windowID] != nil
    }

    /// Key of the registration currently animating `windowID`.
    func key(for windowID: CGWindowID) -> UInt64? {
        active[windowID]?.key
    }

    @discardableResult
    mutating func register(
        windowID: CGWindowID,
        from: CGRect,
        to: CGRect,
        duration: Double,
        easing: MotionEasing
    ) -> RegisterResult {
        var superseded: Finished?
        var effectiveFrom = from
        var seed = [0.0, 0.0, 0.0, 0.0]

        if let old = active[windowID] {
            superseded = Finished(windowID: windowID, key: old.key, settled: false)
            // Replace mid-flight from wherever the animation actually is,
            // not the caller's (stale) idea of the current frame.
            if let start = old.startTime {
                // A supersede arriving between ticks evaluates at the old
                // registration's last known clock position — the next tick
                // re-quantizes the replacement anyway.
                let elapsed = max(0, lastTickTime - start)
                effectiveFrom = Self.evaluate(old, elapsed: elapsed)
                if old.easing == .spring, easing == .spring, let springs = old.springs {
                    seed = springs.map { $0.velocity(at: elapsed) }
                }
            } else {
                effectiveFrom = old.from
            }
        }

        let key = nextKey
        nextKey += 1
        active[windowID] = Registration(
            key: key,
            to: to,
            duration: max(0, duration),
            easing: easing,
            from: effectiveFrom,
            startTime: nil,
            seedVelocity: seed,
            springs: nil,
            lastWritten: effectiveFrom.motionRounded
        )
        return RegisterResult(key: key, superseded: superseded)
    }

    mutating func markStalled(windowID: CGWindowID) {
        active[windowID]?.stalled = true
    }

    @discardableResult
    mutating func cancel(windowID: CGWindowID) -> Finished? {
        guard let old = active.removeValue(forKey: windowID) else { return nil }
        return Finished(windowID: windowID, key: old.key, settled: false)
    }

    private var lastTickTime: Double = 0

    /// Registered windows, ascending.
    var windowIDs: [CGWindowID] { active.keys.sorted() }

    /// Advance the animations of `only` (every window when nil). A window
    /// outside `only` is untouched, and its start time stays unassigned
    /// until a tick covers it — windows ticked by the same clock still
    /// start together.
    mutating func tick(now: Double, only: Set<CGWindowID>? = nil) -> (writes: [FrameWrite], finished: [Finished]) {
        lastTickTime = now
        var writes: [FrameWrite] = []
        var finished: [Finished] = []

        for windowID in active.keys.sorted() where only?.contains(windowID) ?? true {
            guard var reg = active[windowID] else { continue }

            let startTime: Double
            if let assigned = reg.startTime {
                startTime = assigned
            } else {
                startTime = now
                reg.startTime = now
                if reg.easing == .spring {
                    reg.springs = Self.makeSprings(from: reg.from, to: reg.to, seed: reg.seedVelocity)
                }
            }
            let elapsed = max(0, now - startTime)

            if Self.isComplete(reg, elapsed: elapsed) {
                writes.append(FrameWrite(windowID: windowID, frame: reg.to.motionRounded, isFinal: true,
                                         order: .pick(current: reg.lastWritten, target: reg.to.motionRounded)))
                finished.append(Finished(windowID: windowID, key: reg.key, settled: true))
                active[windowID] = nil
                continue
            }

            let frame = Self.evaluate(reg, elapsed: elapsed).motionRounded
            if frame != reg.lastWritten && !reg.stalled {
                writes.append(FrameWrite(windowID: windowID, frame: frame, isFinal: false,
                                         writeSize: frame.size != reg.lastWritten.size,
                                         writePosition: frame.origin != reg.lastWritten.origin,
                                         order: .pick(current: reg.lastWritten, target: frame)))
                reg.lastWritten = frame
            }
            active[windowID] = reg
        }
        return (writes, finished)
    }

    private static func makeSprings(from: CGRect, to: CGRect, seed: [Double]) -> [MotionMath.Spring] {
        let f = [from.origin.x, from.origin.y, from.size.width, from.size.height].map(Double.init)
        let t = [to.origin.x, to.origin.y, to.size.width, to.size.height].map(Double.init)
        return (0..<4).map { MotionMath.Spring(from: f[$0], target: t[$0], initialVelocity: seed[$0]) }
    }

    private static func isComplete(_ reg: Registration, elapsed: Double) -> Bool {
        if reg.from.motionRounded == reg.to.motionRounded { return true }
        switch reg.easing {
        case .spring:
            guard let springs = reg.springs else { return false }
            return springs.allSatisfy {
                $0.isSettled(at: elapsed, epsilon: settleEpsilon, velocityEpsilon: settleVelocityEpsilon)
            }
        case .linear, .easeOutCubic:
            return reg.duration <= 0 || elapsed >= reg.duration
        }
    }

    private static func evaluate(_ reg: Registration, elapsed: Double) -> CGRect {
        switch reg.easing {
        case .spring:
            // Springs exist once startTime is assigned; before that the
            // registration is by definition still at `from`.
            guard let springs = reg.springs else { return reg.from }
            return CGRect(
                x: springs[0].value(at: elapsed),
                y: springs[1].value(at: elapsed),
                width: springs[2].value(at: elapsed),
                height: springs[3].value(at: elapsed)
            )
        case .linear, .easeOutCubic:
            guard reg.duration > 0 else { return reg.to }
            let t = elapsed / reg.duration
            let p = reg.easing == .linear ? MotionMath.linear(t) : MotionMath.easeOutCubic(t)
            return CGRect(
                x: Double(reg.from.origin.x) + (Double(reg.to.origin.x) - Double(reg.from.origin.x)) * p,
                y: Double(reg.from.origin.y) + (Double(reg.to.origin.y) - Double(reg.from.origin.y)) * p,
                width: Double(reg.from.size.width) + (Double(reg.to.size.width) - Double(reg.from.size.width)) * p,
                height: Double(reg.from.size.height) + (Double(reg.to.size.height) - Double(reg.from.size.height)) * p
            )
        }
    }
}

/// Record of frames the daemon wrote, per window. Two consumers:
///
///  - `isSelf` — classifies an incoming AX moved/resized notification as an
///    echo of our own write vs. a user/app-initiated change, so bangs can
///    carry `self: true|false` and window-managing stacks stop
///    re-implementing echo suppression in JS.
///  - `verify` — after a probed write's read-back, decides converged /
///    retry-once / refused, learning per-window size quanta on the way
///    (Terminal-style grid snapping is convergence, not refusal).
///
/// Main-thread only, like every other WindowsByID mutable. Instantiable for
/// tests; production uses `.shared`.
final class FrameLedger {
    static let shared = FrameLedger()

    enum Verdict: Equatable {
        case converged
        case retry
        case refused
    }

    // Echo classification: windowscape's proven real-vs-echo cutoff was
    // 20px/component; AX echoes were observed trailing writes by several
    // hundred ms, so 1.5s covers them with margin without masking a user
    // grabbing the window right after a tile pass.
    private static let echoTolerance: CGFloat = 20
    private static let echoTTL: Double = 1.5
    // Verification: positions are honored or refused outright; sizes may
    // legitimately snap to an app grid — learnable up to 16pt (larger
    // deltas are clamps, not grids).
    private static let positionTolerance: CGFloat = 2
    private static let sizeToleranceFloor: CGFloat = 2
    private static let maxLearnableQuantum: CGFloat = 16

    private struct Applied {
        var frame: CGRect
        var at: Double
    }

    private var lastApplied: [CGWindowID: Applied] = [:]
    private var sizeQuantum: [CGWindowID: CGSize] = [:]
    private var retryUsed: Set<CGWindowID> = []
    private var writeGeneration: [CGWindowID: UInt64] = [:]
    // Size the app held the window at after refusing a target size, keyed
    // to that target size.
    private var enforced: [CGWindowID: (target: CGSize, size: CGSize)] = [:]

    func recordWrite(windowID: CGWindowID, frame: CGRect, now: Double = CFAbsoluteTimeGetCurrent()) {
        lastApplied[windowID] = Applied(frame: frame, at: now)
        writeGeneration[windowID, default: 0] += 1
    }

    /// Monotonic per-window write counter. A deferred verification (the
    /// probe's 60ms read-back + retry) captures the generation after its
    /// own write and aborts its RE-APPLY if any newer write arrived in the
    /// gap — without this, a probe retry during a rapid write stream
    /// (gesture resize, animated tile pass) re-applies a STALE frame
    /// 60-120ms after newer frames already landed, and the window fights
    /// backwards.
    func generation(windowID: CGWindowID) -> UInt64 {
        writeGeneration[windowID] ?? 0
    }

    func clear(windowID: CGWindowID) {
        lastApplied[windowID] = nil
        sizeQuantum[windowID] = nil
        retryUsed.remove(windowID)
        writeGeneration[windowID] = nil
        enforced[windowID] = nil
    }

    /// The size the app enforced the last time it refused `targetSize` for
    /// this window, so animation steps toward that same target can move the
    /// window at the size it will end up at instead of re-asserting a size
    /// the app rejects every frame. Asking with a different target size
    /// forgets the refusal: the new size may well be honored.
    func enforcedSize(windowID: CGWindowID, targetSize: CGSize) -> CGSize? {
        guard let e = enforced[windowID] else { return nil }
        if abs(e.target.width - targetSize.width) < 0.5, abs(e.target.height - targetSize.height) < 0.5 {
            return e.size
        }
        enforced[windowID] = nil
        return nil
    }

    func isSelf(windowID: CGWindowID, observed: CGRect, now: Double) -> Bool {
        guard let applied = lastApplied[windowID] else { return false }
        guard now - applied.at <= Self.echoTTL else { return false }
        let q = sizeQuantum[windowID] ?? .zero
        return abs(observed.origin.x - applied.frame.origin.x) <= Self.echoTolerance
            && abs(observed.origin.y - applied.frame.origin.y) <= Self.echoTolerance
            && abs(observed.size.width - applied.frame.size.width) <= Self.echoTolerance + q.width
            && abs(observed.size.height - applied.frame.size.height) <= Self.echoTolerance + q.height
    }

    func verify(windowID: CGWindowID, target: CGRect, observed: CGRect,
                now: Double = CFAbsoluteTimeGetCurrent()) -> Verdict {
        let dx = abs(observed.origin.x - target.origin.x)
        let dy = abs(observed.origin.y - target.origin.y)
        let dw = abs(observed.size.width - target.size.width)
        let dh = abs(observed.size.height - target.size.height)
        let q = sizeQuantum[windowID] ?? .zero

        if dx <= Self.positionTolerance, dy <= Self.positionTolerance,
           dw <= max(Self.sizeToleranceFloor, q.width),
           dh <= max(Self.sizeToleranceFloor, q.height) {
            retryUsed.remove(windowID)
            enforced[windowID] = nil
            return .converged
        }

        if !retryUsed.contains(windowID) {
            retryUsed.insert(windowID)
            return .retry
        }
        retryUsed.remove(windowID)

        // Terminal mismatch. Whatever the app settled on IS the frame we
        // caused — track it so the app's clamp echo classifies as self.
        recordWrite(windowID: windowID, frame: observed, now: now)

        if dx <= Self.positionTolerance, dy <= Self.positionTolerance,
           dw <= Self.maxLearnableQuantum, dh <= Self.maxLearnableQuantum {
            let existing = sizeQuantum[windowID] ?? .zero
            sizeQuantum[windowID] = CGSize(
                width: max(existing.width, dw.rounded(.up)),
                height: max(existing.height, dh.rounded(.up))
            )
            enforced[windowID] = nil
            return .converged
        }
        if dw > Self.sizeToleranceFloor || dh > Self.sizeToleranceFloor {
            enforced[windowID] = (target: target.size, size: observed.size)
        }
        return .refused
    }
}

/// Write queue policy for one app's AX writer. Latest frame wins per
/// window, and at most one drain is in flight: frames posted while a drain
/// runs wait, replacing each other, and the drain's finish asks for another
/// pass when any arrived. The settle frame and instant writes that race an
/// animation go through the same mailbox, so a write for a window can never
/// land before an older one.
///
/// Main-thread state; only the batch handed out by `take` crosses to the
/// writer's queue.
struct MotionWriteMailbox {
    struct Entry: Equatable {
        var write: MotionPlanner.FrameWrite
        /// The motion registration the write belongs to (0 for an instant
        /// write). A result whose generation is no longer current is stale.
        var generation: UInt64
        /// Callback ids to run with the write's outcome once it lands.
        var callbacks: [UInt64] = []
    }

    private var pending: [CGWindowID: Entry] = [:]
    private var order: [CGWindowID] = []
    private var inFlight: Set<CGWindowID> = []
    private(set) var draining = false

    var isIdle: Bool { !draining && pending.isEmpty }

    func involves(_ windowID: CGWindowID) -> Bool {
        pending[windowID] != nil || inFlight.contains(windowID)
    }

    /// Queue `entry`. True when no drain is running: the caller takes the
    /// batch and starts one now.
    mutating func post(_ entry: Entry) -> Bool {
        let wid = entry.write.windowID
        if let old = pending[wid] {
            var merged = entry
            // An axis the replaced write would have changed still has to be
            // written, or a size step followed by a position-only step
            // would lose the size.
            merged.write.writeSize = entry.write.writeSize || old.write.writeSize
            merged.write.writePosition = entry.write.writePosition || old.write.writePosition
            merged.callbacks = old.callbacks + entry.callbacks
            pending[wid] = merged
        } else {
            pending[wid] = entry
            order.append(wid)
        }
        return !draining
    }

    /// Everything pending, first-seen order, now in flight.
    mutating func take() -> [Entry] {
        let batch = order.compactMap { pending[$0] }
        pending = [:]
        order = []
        inFlight = Set(batch.map { $0.write.windowID })
        draining = true
        return batch
    }

    /// The in-flight batch landed. True when newer entries are waiting: the
    /// caller takes them and drains again.
    mutating func finish() -> Bool {
        inFlight = []
        draining = false
        return !pending.isEmpty
    }
}

private extension CGRect {
    /// AX frames are integral; rounding here is also what powers the
    /// skip-unchanged write suppression (most ticks near the end of an
    /// ease-out land on the same pixel).
    var motionRounded: CGRect {
        CGRect(
            x: origin.x.rounded(),
            y: origin.y.rounded(),
            width: size.width.rounded(),
            height: size.height.rounded()
        )
    }
}

/// Per-app cache of the AXEnhancedUserInterface probe, so a write batch
/// doesn't pay an extra AX read every frame. Entries age out after `ttl`:
/// assistive tools flip the attribute at runtime, and a stale "on" would
/// have the batch restore it to on after the tool turned it off.
struct AXEnhancedUIProbeCache {
    static let ttl: Double = 1.0
    private var entry: (value: Bool?, at: Double)?

    mutating func value(now: Double, probe: () -> Bool?) -> Bool? {
        if let e = entry, now - e.at < Self.ttl { return e.value }
        let v = probe()
        entry = (value: v, at: now)
        return v
    }
}

/// One serial queue per app for AX work that must stay off main: motion
/// writes, the confirmed focused-window read, the focus raise. A slow or
/// hung app backs up only its own queue, and two AX conversations with one
/// app never run concurrently. Main thread only.
enum AXAppQueues {
    private static var queues: [pid_t: DispatchQueue] = [:]

    static func queue(for pid: pid_t) -> DispatchQueue {
        if let q = queues[pid] { return q }
        let q = DispatchQueue(label: "stackd.ax.\(pid)", qos: .userInteractive)
        queues[pid] = q
        return q
    }
}

/// One app's AX writer: a serial queue the writes run on, and the mailbox
/// (main-thread state) that feeds it. A slow or hung app only backs up its
/// own queue; the display-link tick and every other app keep moving.
/// Every motion write for a window goes through its app's one serial queue,
/// so two writes to the same window never run concurrently.
final class AppFrameWriter {
    let pid: pid_t
    let queue: DispatchQueue
    var mailbox = MotionWriteMailbox()
    /// Element per window for the next drain. Main thread.
    var elements: [CGWindowID: AXUIElement] = [:]
    /// Writer queue only.
    private let appElement: AXUIElement
    private var enhancedUI = AXEnhancedUIProbeCache()

    init(pid: pid_t) {
        self.pid = pid
        queue = AXAppQueues.queue(for: pid)
        appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
    }

    /// Run one batch of writes with AXEnhancedUserInterface off, restoring
    /// it after when the app had it on. Writer queue only.
    func withEnhancedUIOff<T>(_ body: () -> T) -> T {
        let el = appElement
        let prior = enhancedUI.value(now: CFAbsoluteTimeGetCurrent()) { AXEnhancedUI.read(el) }
        return AXEnhancedUI.scope(el, want: false, prior: prior, body)
    }
}

/// Impure shell: owns the planner, holds a DisplayLinkObserver subscription
/// while any animation is live, and hands each tick's AX writes to the
/// owning app's writer queue.
/// Main-thread only — every entry point is called from `.ax` / `.custom`
/// bridge handlers that already hop to main, the display-link fires
/// subscribers on main, and writer results hop back to main.
final class WindowMotionEngine {
    static let shared = WindowMotionEngine()
    private init() {}

    private var planner = MotionPlanner()
    // One display-link subscription per display with animating windows;
    // key 0 is the all-displays link. Each window ticks on the clock of the
    // display its target lands on, so a 120Hz panel and a 60Hz monitor each
    // animate at their own rate, and windows on one display start together.
    private static let sharedClock: CGDirectDisplayID = 0
    private var clocks: [CGDirectDisplayID: Token] = [:]
    private var clockOf: [CGWindowID: CGDirectDisplayID] = [:]
    private var screenObserver: NSObjectProtocol?
    private var completions: [UInt64: (Bool) -> Void] = [:]
    // AX element resolved once per animation — WindowsByID.elementFor walks
    // the CGWindowList, far too expensive per tick. A stale element mid-
    // animation makes the intermediate writes no-op (-25204 tolerated
    // everywhere else in Windows.swift); the final write re-resolves.
    private var elements: [CGWindowID: AXUIElement] = [:]
    private var writers: [pid_t: AppFrameWriter] = [:]
    // Size the app enforced last time it refused this animation's target
    // size; read once per animation from the FrameLedger.
    private var enforcedSizes: [CGWindowID: CGSize] = [:]
    private var writeCallbacks: [UInt64: (Bool) -> Void] = [:]
    private var nextCallbackID: UInt64 = 1

    /// How a routed frame write ended. Instant and animated failures mean
    /// different things to callers: a failed instant write may still be
    /// worth probing (the app might have applied part of it), while a
    /// superseded animation must NOT be verified against its stale target.
    enum FrameWriteOutcome {
        case instant(ok: Bool)
        case animated(settled: Bool)
    }

    /// The one instant-vs-animated routing decision, shared by every
    /// bridge entry: no options → instant AX write, cancelling any
    /// in-flight animation first so its next tick can't clobber the
    /// instant frame; duration or spring → the engine, easing defaulting
    /// to easeOutCubic, unless Reduce Motion is on and the caller didn't
    /// opt out (see MotionRouting). Keeping the predicate here means
    /// setFrame and setFrameProbed can't drift into animating under
    /// different conditions.
    func performFrameWrite(
        windowID: CGWindowID,
        frame: CGRect,
        duration: Double,
        easing: MotionEasing?,
        respectReduceMotion: Bool = true,
        completion: @escaping (FrameWriteOutcome) -> Void
    ) {
        guard MotionRouting.animates(duration: duration, easing: easing,
                                     reduceMotion: ReduceMotion.enabled,
                                     respectReduceMotion: respectReduceMotion) else {
            instantWriteWins(windowID: windowID)
            let cached = elements.removeValue(forKey: windowID)
            // Animation writes for this window still queued or in flight
            // would land after a direct write; queue behind them instead.
            if WindowsByID.batchSink == nil,
               let el = cached ?? WindowsByID.elementFor(windowID: windowID),
               let writer = writer(for: el, create: false), writer.mailbox.involves(windowID) {
                FrameLedger.shared.recordWrite(windowID: windowID, frame: frame)
                post(MotionPlanner.FrameWrite(windowID: windowID, frame: frame, isFinal: true),
                     element: el, writer: writer, generation: 0) { ok in
                    completion(.instant(ok: ok))
                }
                return
            }
            completion(.instant(ok: WindowsByID.setFrame(
                windowID: windowID,
                x: frame.origin.x, y: frame.origin.y,
                w: frame.size.width, h: frame.size.height)))
            return
        }
        animate(windowID: windowID, to: frame, duration: duration,
                easing: easing ?? .easeOutCubic) { settled in
            completion(.animated(settled: settled))
        }
    }

    func animate(
        windowID: CGWindowID,
        to: CGRect,
        duration: Double,
        easing: MotionEasing,
        completion: @escaping (Bool) -> Void
    ) {
        // One element resolution; the from-frame reads off the element
        // directly. WindowsByID.frame(windowID:) would repeat the full
        // CGWindowList walk elementFor just paid — twice per window at
        // the exact moment the first animation frame should render.
        guard let el = WindowsByID.elementFor(windowID: windowID),
              let current = Self.axFrame(of: el)
        else {
            completion(false)
            return
        }
        elements[windowID] = el
        enforcedSizes[windowID] = FrameLedger.shared.enforcedSize(windowID: windowID, targetSize: to.size)
        let result = planner.register(
            windowID: windowID, from: current, to: to,
            duration: duration, easing: easing
        )
        if let old = result.superseded { resolve(old) }
        completions[result.key] = completion
        let clock = clockDisplay(for: to)
        clockOf[windowID] = clock
        ensureClock(clock)
    }

    /// An instant setFrame taking effect while an animation is in flight
    /// wins — the animation is cancelled so it can't overwrite the instant
    /// frame on its next tick.
    func instantWriteWins(windowID: CGWindowID) {
        if let old = planner.cancel(windowID: windowID) {
            resolve(old)
            enforcedSizes[windowID] = nil
            Overlay.endCommandedFrame(wid: windowID)
        }
    }

    @discardableResult
    func cancel(windowID: CGWindowID) -> Bool {
        guard let old = planner.cancel(windowID: windowID) else { return false }
        resolve(old)
        elements[windowID] = nil
        enforcedSizes[windowID] = nil
        Overlay.endCommandedFrame(wid: windowID)
        return true
    }

    func isAnimating(windowID: CGWindowID) -> Bool {
        planner.isAnimating(windowID)
    }

    /// Frame read straight off an already-resolved element. Fine as the
    /// animation's from-frame: at animate() time no write is in flight for
    /// this window, so the AX-cached-requested-value staleness that makes
    /// probe read-backs use CG bounds doesn't apply.
    private static func axFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard let posVal = posRef, AXValueGetValue(posVal as! AXValue, .cgPoint, &pos),
              let sizeVal = sizeRef, AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// The all-displays link on a single display (where it is the same
    /// clock), per-display links otherwise.
    private func clockDisplay(for target: CGRect) -> CGDirectDisplayID {
        let displays = MotionClock.activeDisplays()
        guard displays.count > 1 else { return Self.sharedClock }
        return MotionClock.display(for: target, displays: displays) ?? Self.sharedClock
    }

    private func ensureClock(_ display: CGDirectDisplayID) {
        installScreenObserver()
        guard clocks[display] == nil else { return }
        let observer = display == Self.sharedClock
            ? DisplayLinkObserver.shared : DisplayLinkObserver.forDisplay(display)
        let token = observer.subscribe { [weak self] in self?.tick(display) }
        guard observer.isActive || display == Self.sharedClock else {
            // No link for that display (it just went away): the
            // all-displays link takes its windows.
            token.cancel()
            moveAllToSharedClock(from: display)
            return
        }
        clocks[display] = token
    }

    /// Displays changed: per-display links may be gone or rebound, so
    /// every animating window finishes on the all-displays link.
    private func installScreenObserver() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.moveAllToSharedClock(from: nil) }
    }

    private func moveAllToSharedClock(from display: CGDirectDisplayID?) {
        var moved = false
        for (wid, d) in clockOf where d != Self.sharedClock && (display == nil || d == display) {
            clockOf[wid] = Self.sharedClock
            moved = true
        }
        if moved { ensureClock(Self.sharedClock) }
    }

    private func tick(_ display: CGDirectDisplayID) {
        for (wid, _) in clockOf where !planner.isAnimating(wid) { clockOf[wid] = nil }
        let wids = Set(clockOf.filter { $0.value == display }.keys)
        guard !wids.isEmpty else {
            clocks.removeValue(forKey: display)?.cancel()
            if clocks.isEmpty { writers = writers.filter { !$0.value.mailbox.isIdle } }
            return
        }
        let out = planner.tick(now: CFAbsoluteTimeGetCurrent(), only: wids)
        var settles: [CGWindowID: MotionPlanner.Finished] = [:]
        for done in out.finished {
            if done.settled { settles[done.windowID] = done } else { resolve(done) }
        }
        for write in out.writes {
            let settle = write.isFinal ? settles.removeValue(forKey: write.windowID) : nil
            apply(write, settle: settle)
        }
        for done in settles.values { resolve(done) }
    }

    private func apply(_ planned: MotionPlanner.FrameWrite, settle: MotionPlanner.Finished?) {
        let wid = planned.windowID
        let enforced = enforcedSizes[wid]
        if planned.isFinal { enforcedSizes[wid] = nil }
        guard let write = planned.honoring(enforcedSize: enforced) else { return }
        FrameLedger.shared.recordWrite(windowID: wid, frame: write.frame)
        // Overlays on the window follow the frame just commanded, in this
        // same turn, rather than waiting for the window server to report
        // the move. After the settle frame they go back to live reads.
        Overlay.followCommandedFrame(wid: wid, frame: write.frame)
        if write.isFinal { Overlay.endCommandedFrame(wid: wid) }

        let generation = settle?.key ?? planner.key(for: wid) ?? 0
        if write.isFinal {
            let el = elements.removeValue(forKey: wid)
            let done: (Bool) -> Void = { [weak self] _ in
                if let settle = settle { self?.resolve(settle) }
            }
            // Batch mode queues the settle frame in the batch instead.
            guard WindowsByID.batchSink == nil,
                  let element = el ?? WindowsByID.elementFor(windowID: wid),
                  let writer = writer(for: element) else {
                done(WindowsByID.setFrame(
                    windowID: wid,
                    x: write.frame.origin.x, y: write.frame.origin.y,
                    w: write.frame.size.width, h: write.frame.size.height))
                return
            }
            post(write, element: element, writer: writer, generation: generation, callback: done)
            return
        }
        guard let el = elements[wid], let writer = writer(for: el) else { return }
        post(write, element: el, writer: writer, generation: generation, callback: nil)
    }

    private func writer(for element: AXUIElement, create: Bool = true) -> AppFrameWriter? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        if let w = writers[pid] { return w }
        guard create else { return nil }
        let w = AppFrameWriter(pid: pid)
        writers[pid] = w
        return w
    }

    private func post(_ write: MotionPlanner.FrameWrite, element: AXUIElement,
                      writer: AppFrameWriter, generation: UInt64,
                      callback: ((Bool) -> Void)?) {
        var ids: [UInt64] = []
        if let cb = callback {
            let id = nextCallbackID
            nextCallbackID += 1
            writeCallbacks[id] = cb
            ids = [id]
        }
        writer.elements[write.windowID] = element
        if writer.mailbox.post(MotionWriteMailbox.Entry(write: write, generation: generation,
                                                         callbacks: ids)) {
            drain(writer)
        }
    }

    private struct WriteResult {
        let entry: MotionWriteMailbox.Entry
        let ok: Bool
        let timedOut: Bool
    }

    private func drain(_ writer: AppFrameWriter) {
        let batch = writer.mailbox.take()
        let jobs = batch.map { ($0, writer.elements[$0.write.windowID]) }
        writer.queue.async { [weak self] in
            let results = writer.withEnhancedUIOff { jobs.map { entry, element -> WriteResult in
                guard let el = element else { return WriteResult(entry: entry, ok: false, timedOut: false) }
                if entry.write.isFinal {
                    return WriteResult(entry: entry,
                                       ok: WindowsByID.settleFrameAX(element: el, frame: entry.write.frame,
                                                                     order: entry.write.order),
                                       timedOut: false)
                }
                let timedOut = WindowsByID.writeAxesAX(
                    element: el, frame: entry.write.frame,
                    size: entry.write.writeSize, position: entry.write.writePosition,
                    order: entry.write.order,
                    timeout: Self.intermediateWriteTimeout)
                return WriteResult(entry: entry, ok: !timedOut, timedOut: timedOut)
            } }
            DispatchQueue.main.async { self?.finishDrain(writer, results) }
        }
    }

    private func finishDrain(_ writer: AppFrameWriter, _ results: [WriteResult]) {
        for r in results {
            let wid = r.entry.write.windowID
            let current = planner.key(for: wid)
            if r.timedOut, current == r.entry.generation {
                WindowDebug.log("motion: wid=\(wid) stalled — skipping to the final frame")
                planner.markStalled(windowID: wid)
            }
            var ok = r.ok
            if r.entry.write.isFinal, !ok, current == nil {
                // The element went stale; one fresh lookup, as the direct
                // path would.
                let f = r.entry.write.frame
                ok = WindowsByID.setFrame(windowID: wid, x: f.origin.x, y: f.origin.y,
                                          w: f.size.width, h: f.size.height)
            }
            for id in r.entry.callbacks {
                writeCallbacks.removeValue(forKey: id)?(ok)
            }
        }
        if writer.mailbox.finish() {
            drain(writer)
        } else if writer.mailbox.isIdle {
            writer.elements = [:]
        }
    }

    // Bounded so a hung app can't hold its writer queue for the ~6s system
    // default on every frame; generous enough that a busy-but-alive app (a
    // Chromium re-layout) still animates.
    private static let intermediateWriteTimeout: Float = 0.1

    private func resolve(_ finished: MotionPlanner.Finished) {
        guard let completion = completions.removeValue(forKey: finished.key) else { return }
        completion(finished.settled)
    }
}
