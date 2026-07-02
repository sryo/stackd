import Foundation
import CoreGraphics
import ApplicationServices

// Window motion engine — daemon-side animated setFrame.
//
// Split from Windows.swift so the scheduling core stays pure and headless-
// testable (precedent: Display.swift / DisplayDDC.swift). Three layers:
//
//   MotionMath    — easing curves + a critically-damped spring, pure math.
//   MotionPlanner — pure scheduler: registrations in, per-tick AX writes out.
//   WindowMotionEngine — the only impure part: subscribes the shared
//                   CVDisplayLink clock while animations are live and issues
//                   the actual AX writes.
//
// Why daemon-side at all (vs. the JS rAF loop windowscape shipped): every
// animating window is evaluated inside ONE display-link tick on ONE clock,
// so a multi-window tile pass moves in lockstep instead of staggering on
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

/// Pure scheduling core. One registration per window (last-write-wins).
/// Start times are assigned by the FIRST tick a registration sees, not at
/// register time — every window registered between two ticks starts on the
/// same clock instant and evaluates identical `t` forever after. This is
/// the anti-stagger contract: N setFrame RPCs arriving in one runloop
/// burst animate as one choreographed pass.
struct MotionPlanner {
    struct FrameWrite: Equatable {
        let windowID: CGWindowID
        let frame: CGRect
        let isFinal: Bool
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
    }

    private var active: [CGWindowID: Registration] = [:]
    private var nextKey: UInt64 = 1

    var isEmpty: Bool { active.isEmpty }

    func isAnimating(_ windowID: CGWindowID) -> Bool {
        active[windowID] != nil
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

    @discardableResult
    mutating func cancel(windowID: CGWindowID) -> Finished? {
        guard let old = active.removeValue(forKey: windowID) else { return nil }
        return Finished(windowID: windowID, key: old.key, settled: false)
    }

    private var lastTickTime: Double = 0

    mutating func tick(now: Double) -> (writes: [FrameWrite], finished: [Finished]) {
        lastTickTime = now
        var writes: [FrameWrite] = []
        var finished: [Finished] = []

        for windowID in active.keys.sorted() {
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
                writes.append(FrameWrite(windowID: windowID, frame: reg.to.motionRounded, isFinal: true))
                finished.append(Finished(windowID: windowID, key: reg.key, settled: true))
                active[windowID] = nil
                continue
            }

            let frame = Self.evaluate(reg, elapsed: elapsed).motionRounded
            if frame != reg.lastWritten {
                writes.append(FrameWrite(windowID: windowID, frame: frame, isFinal: false))
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
            return .converged
        }
        return .refused
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

/// Impure shell: owns the planner, holds a DisplayLinkObserver subscription
/// while any animation is live, and issues the AX writes each tick.
/// Main-thread only — every entry point is called from `.ax` / `.custom`
/// bridge handlers that already hop to main, and the display-link fires
/// subscribers on main.
final class WindowMotionEngine {
    static let shared = WindowMotionEngine()
    private init() {}

    private var planner = MotionPlanner()
    private var linkToken: Token?
    private var completions: [UInt64: (Bool) -> Void] = [:]
    // AX element resolved once per animation — WindowsByID.elementFor walks
    // the CGWindowList, far too expensive per tick. A stale element mid-
    // animation makes the intermediate writes no-op (-25204 tolerated
    // everywhere else in Windows.swift); the final write re-resolves.
    private var elements: [CGWindowID: AXUIElement] = [:]

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
    /// to easeOutCubic. Keeping the predicate here means setFrame and
    /// setFrameProbed can't drift into animating under different
    /// conditions.
    func performFrameWrite(
        windowID: CGWindowID,
        frame: CGRect,
        duration: Double,
        easing: MotionEasing?,
        completion: @escaping (FrameWriteOutcome) -> Void
    ) {
        guard duration > 0 || easing == .spring else {
            instantWriteWins(windowID: windowID)
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
        let result = planner.register(
            windowID: windowID, from: current, to: to,
            duration: duration, easing: easing
        )
        if let old = result.superseded { resolve(old) }
        completions[result.key] = completion
        ensureClock()
    }

    /// An instant setFrame taking effect while an animation is in flight
    /// wins — the animation is cancelled so it can't overwrite the instant
    /// frame on its next tick.
    func instantWriteWins(windowID: CGWindowID) {
        if let old = planner.cancel(windowID: windowID) {
            resolve(old)
            elements[windowID] = nil
        }
    }

    @discardableResult
    func cancel(windowID: CGWindowID) -> Bool {
        guard let old = planner.cancel(windowID: windowID) else { return false }
        resolve(old)
        elements[windowID] = nil
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

    private func ensureClock() {
        guard linkToken == nil else { return }
        linkToken = DisplayLinkObserver.shared.subscribe { [weak self] in self?.tick() }
    }

    private func tick() {
        guard !planner.isEmpty else {
            linkToken?.cancel()
            linkToken = nil
            return
        }
        let out = planner.tick(now: CFAbsoluteTimeGetCurrent())
        for write in out.writes {
            apply(write)
        }
        for done in out.finished {
            if done.settled { elements[done.windowID] = nil }
            resolve(done)
        }
    }

    private func apply(_ write: MotionPlanner.FrameWrite) {
        FrameLedger.shared.recordWrite(windowID: write.windowID, frame: write.frame)
        if write.isFinal {
            // Full size→pos→size dance with a fresh element lookup — the
            // settle frame is the one that must stick.
            _ = WindowsByID.setFrame(
                windowID: write.windowID,
                x: write.frame.origin.x, y: write.frame.origin.y,
                w: write.frame.size.width, h: write.frame.size.height
            )
            return
        }
        // Intermediate ticks: two writes (size, position) on the cached
        // element. The belt-and-suspenders second size set is deferred to
        // the final frame; per-tick it would double the AX volume for a
        // correction no one can see mid-flight.
        guard let el = elements[write.windowID] else { return }
        var pos = write.frame.origin
        var size = write.frame.size
        guard let posVal = AXValueCreate(.cgPoint, &pos),
              let sizeVal = AXValueCreate(.cgSize, &size) else { return }
        _ = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sizeVal)
        _ = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posVal)
    }

    private func resolve(_ finished: MotionPlanner.Finished) {
        guard let completion = completions.removeValue(forKey: finished.key) else { return }
        completion(finished.settled)
    }
}
