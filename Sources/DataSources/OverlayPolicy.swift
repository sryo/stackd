import AppKit
import CoreGraphics

// Pure decisions behind the window-tracking overlay: geometry, tick
// planning, arming, repin and reveal policy. Nothing here touches a panel
// or the window server, so each type is testable headlessly.

// MARK: - Overlay tick geometry (pure, testable)

/// Pure geometry for the window-tracking overlay tick — panel placement and
/// the per-tick `window.sd.target` payload, both parameterized by `outset`.
/// Separate + pure so the outset math is testable without an NSPanel.
enum OverlayGeometry {
    /// Non-finite or negative outsets fall back to 0 — a negative outset
    /// would shrink the panel INSIDE the target and, past half the target
    /// size, hand NSPanel a negative-size frame.
    static func sanitizeOutset(_ n: CGFloat) -> CGFloat {
        n.isFinite && n > 0 ? n : 0
    }

    /// Panel frame for a target window frame grown by `outset` on all four
    /// sides. Same coordinate space in as out (the tick passes CGS top-left).
    /// Outset 0 is the identity — today's pin-exactly behavior.
    static func panelFrame(target: CGRect, outset: CGFloat) -> CGRect {
        target.insetBy(dx: -outset, dy: -outset)
    }

    /// Panel frame of an explicit `size` (≥ the outset frame's) anchored
    /// top-left, so the target keeps its (outset, outset) panel position
    /// and any extra room hangs off the right and bottom. CGS top-left in
    /// and out.
    static func panelFrame(target: CGRect, outset: CGFloat, size: CGSize) -> CGRect {
        CGRect(x: target.minX - outset, y: target.minY - outset,
               width: size.width, height: size.height)
    }

    /// The {x,y,w,h,outset} object literal in PANEL coordinates — the one
    /// spelling of the payload shape shared by the per-tick push and the
    /// attach-time bootstrap seed (adding a field means editing exactly
    /// here). The target's top-left sits at (outset, outset).
    /// `resizing` is only spelled out while true, so the idle payload stays
    /// byte-identical to the pre-resizing shape (JS reads it as falsy).
    static func targetObjectJS(targetFrame: CGRect, outset: CGFloat, resizing: Bool = false) -> String {
        let o = Int(outset)
        let flag = resizing ? ",resizing:true" : ""
        return "{x:\(o),y:\(o),w:\(Int(targetFrame.width)),h:\(Int(targetFrame.height)),outset:\(o)\(flag)}"
    }

    /// The per-tick JS push. Outset 0 reproduces the legacy `{x:0,y:0,w,h}`
    /// payload plus the new `outset` field.
    static func targetPayloadJS(targetFrame: CGRect, outset: CGFloat, resizing: Bool = false) -> String {
        "window.sd=window.sd||{};window.sd.target=\(targetObjectJS(targetFrame: targetFrame, outset: outset, resizing: resizing));window.dispatchEvent(new CustomEvent('sd:target',{detail:window.sd.target}));"
    }
}

// MARK: - Live resize (pure, testable)

/// Observes whether the target is being live-resized by the user: its size
/// changed within the last `quiet` seconds while the left button is held.
/// Programmatic resizes (tilers, animations) have no button down and never
/// count. The daemon only reports the state; what to do with it (hide the
/// border, drop effects) is the stack's call.
struct LiveResizeDetector {
    static let quiet: Double = 0.060
    private var lastSize: CGSize?
    private var lastChange: Double = -.infinity

    /// `buttonDown` is only evaluated while a size change is recent, so idle
    /// ticks never query the window server.
    mutating func update(size: CGSize, now: Double, buttonDown: () -> Bool) -> Bool {
        if let last = lastSize,
           abs(last.width - size.width) >= 0.5 || abs(last.height - size.height) >= 0.5 {
            lastChange = now
        }
        lastSize = size
        guard now - lastChange < Self.quiet else { return false }
        return buttonDown()
    }
}

// MARK: - Live-resize headroom (pure, testable)

/// Panel size while the user live-resizes the target. Reshaping the panel
/// makes WebKit re-lay out and redisplay on every resize tick, so during a
/// resize the panel is rounded up with `room` to grow into, in `step`
/// increments, and only reshaped when the target outgrows it; in between,
/// resize ticks are window-server moves (or nothing). It is fitted exactly
/// once the resize has paused for `settle`. The extra room hangs off the
/// right and bottom — stacks position off `sd.target`, not the panel edge.
struct OverlayHeadroom {
    static let step: CGFloat = 128
    static let room: CGFloat = 0.5
    static let settle: Double = 0.25

    private var lastResizeAt: Double = -.infinity

    /// `content` is the exactly-fitted panel size (target plus outset),
    /// `current` the panel's size now (nil when unknown or forced).
    /// `limit` is the room from the panel's top-left to the desktop's right
    /// and bottom edges, read only when growing: room past the desktop is
    /// backing store nothing can ever draw into.
    mutating func panelSize(content: CGSize, current: CGSize?, resizing: Bool, now: Double,
                            limit: () -> CGSize? = { nil }) -> CGSize {
        if resizing { lastResizeAt = now }
        guard now - lastResizeAt < Self.settle else { return content }
        if let cur = current, content.width <= cur.width, content.height <= cur.height {
            return cur
        }
        var grown = CGSize(width: Self.roundUp(content.width * (1 + Self.room)),
                           height: Self.roundUp(content.height * (1 + Self.room)))
        if let cap = limit() {
            grown.width = max(content.width, min(grown.width, cap.width))
            grown.height = max(content.height, min(grown.height, cap.height))
        }
        return grown
    }

    private static func roundUp(_ v: CGFloat) -> CGFloat {
        (v / step).rounded(.up) * step
    }
}

// MARK: - Tick plan (pure, testable)

/// What a panel frame update costs. A move only changes the origin, so the
/// WebView's layout is untouched and no redisplay is needed; a reshape
/// resizes the web content and must go through a displaying setFrame.
enum OverlayFrameOp: Equatable {
    case none
    case move(CGPoint)
    case reshape(CGRect)
}

/// Per-tick decisions for `OverlayHandle.tick`, split out so the "skip work
/// when nothing changed" rules are testable without a panel or WebView.
enum OverlayTickPlan {
    /// `last == .zero` is the "force" sentinel (first tick, requested repin)
    /// and always yields a reshape. Sub-0.5pt jitter from CGS round-trips is
    /// treated as unchanged.
    static func frameOp(next: CGRect, last: CGRect) -> OverlayFrameOp {
        let sameOrigin = abs(next.origin.x - last.origin.x) < 0.5 &&
                         abs(next.origin.y - last.origin.y) < 0.5
        let sameSize = abs(next.width - last.width) < 0.5 &&
                       abs(next.height - last.height) < 0.5
        if sameSize && last != .zero { return sameOrigin ? .none : .move(next.origin) }
        return .reshape(next)
    }

    /// How long the panel must have gone without a window-server move before
    /// AppKit's cached origin is resynced. Shorter than OverlayTickArm.idle
    /// so the armed tick is still running when it passes.
    static let appKitSyncSettle: Double = 0.05

    /// After window-server moves, AppKit's cached origin is resynced on the
    /// first tick with no frame change once the panel has been still for
    /// `appKitSyncSettle` — never mid-motion, where it would put the AppKit
    /// round-trip back on the hot path. A drag reports moves at about 50 Hz
    /// against a 60 Hz vsync, so one quiet tick is routine inside a drag. A
    /// reshape goes through setFrame, which resyncs by itself.
    static func needsAppKitSync(frameOp: OverlayFrameOp, appKitStale: Bool,
                                sinceLastServerMove: Double = .infinity) -> Bool {
        appKitStale && frameOp == .none && sinceLastServerMove >= appKitSyncSettle
    }

    /// Whether the panel keeps OverlayHeadroom's spare room instead of being
    /// fitted to the target: during a live resize, and while the motion
    /// engine animates the target. A fitted panel is an AppKit resize on
    /// every frame of the animation, each one a window-server update the
    /// server can hold for about half a second while the target's app
    /// commits its own animated frames; with room the panel only moves until
    /// the target settles.
    static func holdsHeadroom(liveResize: Bool, commanded: Bool) -> Bool {
        liveResize || commanded
    }

    /// The payload is in panel coordinates, so it only changes on resize or
    /// outset change — never on a pure move.
    static func payloadToPush(_ js: String, lastPushed: String?) -> String? {
        js == lastPushed ? nil : js
    }
}

// MARK: - Frame source (pure, testable)

/// Where a tick takes the target frame from. While the daemon animates the
/// target, the frame it commanded is ahead of anything the window server can
/// report yet, so the panel follows the command and never reads live bounds
/// mid-animation (reading them would pull it back to the lagging window).
enum OverlayFrameSource {
    static func targetFrame(commanded: CGRect?, live: () -> CGRect?) -> CGRect? {
        if let c = commanded { return c }
        return live()
    }
}

// MARK: - Target push (pure, testable)

/// At most one `sd.target` evaluateJavaScript in flight per overlay. A
/// resize changes the payload every vsync, and WebKit queues every eval it
/// is handed; when the web process falls behind, the backlog makes the
/// overlay replay stale sizes. Payloads offered while one is outstanding
/// replace each other, and only the newest is sent once it completes.
// MARK: - Cross-display reveal (pure, testable)

enum OverlayScreens {
    /// True when `from` and `to` sit on different screens (by center point,
    /// AppKit coordinates). A `.zero` or off-screen `from` is a first
    /// placement, not a crossing.
    static func crossesScreens(from: CGRect, to: CGRect, screens: [CGRect]) -> Bool {
        guard from != .zero else { return false }
        func index(_ r: CGRect) -> Int? {
            screens.firstIndex { $0.contains(CGPoint(x: r.midX, y: r.midY)) }
        }
        guard let a = index(from), let b = index(to) else { return false }
        return a != b
    }

    /// True when a retarget from panel frame `from` to `to` needs the
    /// WebView to repaint before the panel shows the right border: a new
    /// size (the border is laid out for the old one) or another display (a
    /// new backing scale). A same-size move only translates the panel.
    static func retargetRepaints(from: CGRect, to: CGRect, screens: [CGRect]) -> Bool {
        guard from != .zero else { return false }
        let resized = abs(from.width - to.width) >= 0.5 || abs(from.height - to.height) >= 0.5
        return resized || crossesScreens(from: from, to: to, screens: screens)
    }
}

/// Holds a window-attached panel transparent after a retarget that resized
/// it or moved it to another display. Either makes the WebView repaint, and
/// until it does the compositor shows the previous target's border stretched
/// over the new frame. Revealed by a confirm that the page painted (issued
/// only once the target push is idle, so it lands after the new geometry),
/// or by a fallback. Every retarget while hidden restarts the wait; a
/// confirm or fallback for an older generation is ignored.
struct OverlayRevealGate {
    private(set) var hiddenGeneration: Int?
    private var generation = 0
    private var confirming: Int?

    /// Returns true when the caller must hide the panel now.
    mutating func retargeted(repaints: Bool) -> Bool {
        guard repaints || hiddenGeneration != nil else { return false }
        let wasHidden = hiddenGeneration != nil
        generation += 1
        hiddenGeneration = generation
        confirming = nil
        return !wasHidden
    }

    /// The generation to confirm a paint for, or nil when nothing is hidden,
    /// a confirm is already out, or a target push hasn't finished.
    mutating func confirmation(pushInFlight: Bool) -> Int? {
        guard let h = hiddenGeneration, confirming == nil, !pushInFlight else { return nil }
        confirming = h
        return h
    }

    /// Returns true when the caller must reveal the panel now.
    mutating func confirmed(generation g: Int) -> Bool {
        if confirming == g { confirming = nil }
        guard hiddenGeneration == g else { return false }
        hiddenGeneration = nil
        return true
    }

    mutating func fallback(generation g: Int) -> Bool {
        confirmed(generation: g)
    }
}

struct NewestWinsPush {
    private(set) var inFlight = false
    private var held: String?

    /// The payload to send now, or nil when one is already in flight (the
    /// payload is held instead, replacing any older held one).
    mutating func offer(_ js: String) -> String? {
        if inFlight {
            held = js
            return nil
        }
        inFlight = true
        return js
    }

    /// The in-flight eval finished. Returns the held payload to send next
    /// (which becomes the one in flight), or nil and goes idle.
    mutating func complete() -> String? {
        if let next = held {
            held = nil
            return next
        }
        inFlight = false
        return nil
    }
}

// MARK: - Pending page eval (pure, testable)

/// Scripts for an overlay page, which WebKit only takes once it has loaded.
/// Until then every script is held, in order, and the load runs them as
/// one; after it they pass straight through.
struct PendingPageEval {
    private(set) var loaded = false
    private var held: String?

    /// The script to run now, or nil when it is held for the load.
    mutating func offer(_ js: String) -> String? {
        if loaded { return js }
        held = (held ?? "") + ";" + js
        return nil
    }

    /// The page finished loading: everything held, as one script.
    mutating func pageLoaded() -> String? {
        loaded = true
        defer { held = nil }
        return held
    }
}

// MARK: - Repin policy (pure, testable)

/// Decides when a tick must re-assert the panel's z-order above its target.
///
/// Primary signal is event-driven: frame changes (move/resize/retarget) and
/// explicit repins (CGS 808 "window reordered" for the target wid, routed
/// via `Overlay.notifyWindowReordered`). The cadence is a SAFETY CEILING,
/// not the mechanism: 808 is registered per-connection in WindowEvents and
/// is yabai's canonical reorder source, but a listener that registers fine
/// can silently never fire, so we don't trust an unverified listener alone
/// for a user-visible invariant. It is measured in seconds because ticks
/// only run while armed or on the backstop; an idle overlay reorders on
/// every other backstop tick. One SLSTransactionOrderWindow per cadence is
/// a single WindowServer transaction — imperceptible cost against "border
/// silently behind its own target until the next move."
enum OverlayRepinPolicy {
    /// Chosen ceiling — raises that 808 misses stay wrong for at most this
    /// long (plus up to one backstop interval).
    static let reorderCadence: Double = 1.0

    static func shouldReorder(frameChanged: Bool, sinceReorder: Double) -> Bool {
        frameChanged || sinceReorder >= reorderCadence
    }
}

// MARK: - Stall trace

/// STACKD_WIN_DEBUG only: the overlay's last window-server writes, logged
/// when one observation holds the main thread long enough to drop frames,
/// so a stall names what the panel did just before it. Offsets are ms
/// relative to the start of the blocked observation.
struct OverlayTrace {
    static let stallThreshold = 0.05
    private var ops: [(t: Double, op: String)] = []

    mutating func note(_ op: @autoclosure () -> String) {
        guard WindowDebug.enabled else { return }
        ops.append((CFAbsoluteTimeGetCurrent(), op()))
        if ops.count > 12 { ops.removeFirst(ops.count - 12) }
    }

    mutating func tickEnded(start: Double) {
        guard WindowDebug.enabled else { return }
        guard let line = Self.report(start: start, end: CFAbsoluteTimeGetCurrent(), ops: ops) else { return }
        WindowDebug.log(line)
    }

    static func report(start: Double, end: Double, ops: [(t: Double, op: String)]) -> String? {
        guard end - start > stallThreshold else { return nil }
        let ms = { (s: Double) in Int((s * 1000).rounded()) }
        let recent = ops.map { "\($0.op)@\(ms($0.t - start))" }.joined(separator: " ")
        return "overlay: tick blocked \(ms(end - start))ms; before: \(recent)"
    }
}

// MARK: - Target level (pure, testable)

/// The window level a window-attached panel sits at, derived from its
/// target's level: the band just under the Dock for any target below it,
/// otherwise one level above the target. The panel is then always above its
/// target, however the target is raised or lowered inside its own level, and
/// under the Dock, the menu bar and notifications. The trade: other app
/// windows in front of the target no longer cover the border.
///
/// The panel never shares its target's level. Within one level the window
/// server keeps whatever order the last raise left, so a shared level puts
/// the border behind its target whenever a raise (a click, an app bringing
/// its window forward) reaches the server after the panel's own reorder or
/// without a reorder event the overlay sees. One level up needs no reorder
/// to stay in front.
///
/// The target's level is one window-server read per target, cached for
/// that wid. A retarget reads the new target; a repin (`refresh`) re-reads
/// so a target that changed level in place is picked up.
/// A read that fails keeps the level already known for the same target, or
/// falls back to the normal level for a new one and tries again next time.
struct OverlayTargetLevel {
    static let fallback = NSWindow.Level.normal.rawValue
    /// The level just under the Dock, above every level app windows
    /// normally use (normal, floating, modal panels).
    static let underDock = NSWindow.Level.dock.rawValue - 1

    static func panelLevel(above target: Int) -> Int {
        max(underDock, target + 1)
    }

    private var wid: CGWindowID = 0
    private var level: Int?

    mutating func resolve(target: CGWindowID, refresh: Bool, read: (CGWindowID) -> Int?) -> Int {
        if target != wid {
            wid = target
            level = nil
        }
        if level == nil || refresh, let fresh = read(target) {
            level = fresh
        }
        return level ?? Self.fallback
    }
}

// MARK: - Tick arming (pure, testable)

/// When a window-tracking overlay runs its per-vsync tick. Each tick costs
/// two window-server reads (SLSWindowIsOrderedIn + SLSGetWindowBounds), so
/// an idle overlay shouldn't pay them every frame forever.
///
/// Events that say the target may be changing arm the tick: AX moved /
/// resized / minimized / deminimized / focused and CGS reorder / destroy
/// (through the host's window bangs), daemon-driven frame writes, retarget,
/// outset change, app hide / unhide, space and display changes. Once armed
/// the tick keeps itself alive while the frame or visibility keeps changing
/// (and while a mouse button is held, so a paused drag resumes without
/// waiting for the next coalesced AX event, or the target is mid system
/// animation, so the panel returns on the frame the animation ends), and
/// disarms after `idle` seconds of no change.
///
/// Apps that move or resize windows without posting AX notifications, and
/// windows that vanish silently, are caught by the backstop: one tick every
/// `backstopInterval` while disarmed, which arms the vsync tick as soon as
/// it sees a change. That interval is a chosen ceiling on how stale an
/// overlay can be for a target nothing tells us about.
struct OverlayTickArm {
    static let idle: Double = 0.100
    static let backstopInterval: Double = 0.5
    /// Hold for events whose visible effect lands at the end of a system
    /// animation (minimize genie, app hide, space slide).
    static let visibilityHold: Double = 0.6

    private(set) var armed = false
    private var deadline: Double = -.infinity

    var wantsBackstop: Bool { !armed }

    /// Keep ticking until at least `now + hold`. True on the disarmed →
    /// armed edge, where the caller subscribes to vsync.
    mutating func arm(now: Double, hold: Double = OverlayTickArm.idle) -> Bool {
        deadline = max(deadline, now + hold)
        if armed { return false }
        armed = true
        return true
    }

    /// After an armed tick. `changed` = the frame, visibility or payload
    /// changed this tick. `busy` = a mouse button is held or the target is
    /// mid system animation; it is only consulted once the idle spell has
    /// run out. False means disarmed: the caller unsubscribes.
    mutating func afterTick(now: Double, changed: Bool, busy: () -> Bool) -> Bool {
        if changed { deadline = max(deadline, now + Self.idle) }
        if now < deadline { return true }
        if busy() {
            deadline = now + Self.idle
            return true
        }
        armed = false
        return false
    }
}

/// Which host window bangs arm overlay ticks, and for how long. Frame and
/// z-order events arm for the idle spell (the tick then keeps itself alive
/// while the frame moves); visibility events hold through the system
/// animation that precedes the change.
enum OverlayArmEvents {
    static func hold(forBang name: String) -> Double? {
        switch name {
        case "sd.window.moved", "sd.window.resized", "sd.window.reordered",
             "sd.window.focused", "sd.window.focusedByMouse":
            return OverlayTickArm.idle
        case "sd.window.minimized", "sd.window.deminimized", "sd.window.destroyed":
            return OverlayTickArm.visibilityHold
        case "sd.window.animating":
            // The tick then stays armed for as long as the target animates
            // (OverlayTickArm.afterTick's `busy`), so it is running on the
            // frame a deminimizing window's warp ends.
            return OverlayTickArm.idle
        default:
            return nil
        }
    }
}

// MARK: - Window-server event follow (pure, testable)

/// Which overlays track which target windows. Every mutation reports
/// whether the set of distinct target wids changed, so the interest list
/// and the event filter are refreshed only when they have to be.
struct OverlayFollowTargets<Key: Hashable> {
    private var byKey: [Key: UInt32] = [:]

    /// Distinct target wids, ascending.
    var wids: [UInt32] { Array(Set(byKey.values)).sorted() }

    func contains(wid: UInt32) -> Bool { byKey.values.contains(wid) }

    /// Point `key` at `wid` (attach or retarget).
    mutating func set(_ key: Key, wid: UInt32) -> Bool {
        let before = Set(byKey.values)
        byKey[key] = wid
        return Set(byKey.values) != before
    }

    /// Forget `key` (detach).
    mutating func remove(_ key: Key) -> Bool {
        let before = Set(byKey.values)
        byKey[key] = nil
        return Set(byKey.values) != before
    }

    /// Forget every overlay on `wid` (the target was destroyed). A retarget
    /// puts the overlay back through `set`.
    mutating func drop(wid: UInt32) -> Bool {
        let keys = byKey.filter { $0.value == wid }.map { $0.key }
        for k in keys { byKey[k] = nil }
        return !keys.isEmpty
    }
}
