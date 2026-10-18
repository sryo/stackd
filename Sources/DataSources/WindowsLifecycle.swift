import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - WindowsLifecycleObserver: 10s safety backstop for AX lifecycle

// Low-frequency CGWindowList diff that runs alongside `WindowsAXObserver`.
//
// Role: NOT the primary source. AX
// fires create / destroy / title within ~1s of the action. This poll is
// the **drift sensor** per CLAUDE.md ("low-frequency safety timer
// alongside listeners is fine — pure polling for state … could push you
// on is a bug"). When the poll catches a create / destroy / title-change
// that AX didn't fire for in the last 12s, we log `poll missed-by-ax …`.
//
// 10s tick is the chosen ceiling: long enough that idle cost is
// negligible (1 CGWindowList call per 10s = ~1ms work / 10000ms idle),
// short enough that a stuck AX path shows up in a stack author's
// debugging session inside one round of "open a window, watch logs."
// Not lower — the lower the tick, the more we drift toward polling-as-
// primary, which the rule explicitly forbids.
//
// Always-on at startup, same lifetime as the CGS notify loop and
// WindowsAXObserver. The subscriber-count gate from the polling-primary
// era is gone: gating it on `handles: ["sd.window.*"]` made the gate
// itself a single point of failure (manifest parse bug → no source
// runs), and idle cost is zero per the math above.
//
// Fan-out shape stays unchanged: `onCreate` / `onDestroy` /
// `onTitleChange` are the same callbacks AppDelegate sets up, so AX and
// the poll feed the same bang surface.
final class WindowsLifecycleObserver {
    static let shared = WindowsLifecycleObserver()

    struct Snap {
        let id: Int
        let pid: Int
        let app: String
        let title: String
        let frame: CGRect
    }

    var onCreate:       ((Snap) -> Void)?
    var onDestroy:      ((Snap) -> Void)?
    var onTitleChange:  ((Snap, String) -> Void)?  // (new, oldTitle)
    var onPumpNudge:    (() -> Void)?              // channel-only push, no bangs

    private var snapshot: [Int: Snap] = [:]
    private var timer: Timer?
    private var coverageGate = PerWindowCoverage.Gate()

    private init() {}

    /// Install the safety-backstop poll. Always-on, idempotent. AppDelegate
    /// calls this once at startup, same lifetime as WindowsAXObserver and
    /// WindowEvents.install — no per-stack gating, no Token to adopt.
    func install() {
        guard timer == nil else { return }
        snapshot = current()        // seed without firing on first tick
        // Cold-start convergence: the seed (and every stack's boot replay
        // of sd.windows.all) is taken while AX probes are still timing out
        // en masse, so it under-counts the real window list. Two early
        // ticks close that gap in ~1-3s — without them the first repeating
        // tick at +10s fires the catch-up "created" storm after a 10s
        // window in which freshly-booted stacks are blind to most windows.
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.tick()
            }
        }
        let t = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let rows = Windows.all()
        let now = current(rows)
        if Self.shouldSkipTick(previousCount: snapshot.count, currentCount: now.count) {
            WindowDebug.log("poll tick skipped: window list read empty (transient)")
            return
        }
        let diff = WindowsLifecycleObserver.diff(prev: snapshot, next: now)

        // Fire diffs that AX didn't already cover. AX writes
        // `lastAxFire[wid] = now` on every callback; if it's fresh for a
        // wid (within ~12s, i.e. one tick + safety margin), the poll
        // signal is redundant and we silently drop it. If it's stale OR
        // missing entirely, AX missed the event — fire the callback so
        // userland sees it, AND log `poll missed-by-ax` as the drift
        // sensor per CLAUDE.md.
        var missedDestroyed = 0, missedTitled = 0
        let creates = Self.pollCreateActions(
            created: diff.created,
            axCovered: { self.axCoveredRecently(wid: CGWindowID($0)) },
            announced: { WindowLifecycleFanout.announcedRecently(id: $0) })
        let missedCreated = creates.announce.count
        for snap in creates.announce {
            onCreate?(snap)
            WindowsAXObserver.shared.ensurePerWindow(pid: pid_t(snap.pid), wid: CGWindowID(snap.id))
        }
        if creates.pumpNudge { onPumpNudge?() }
        // Only a destroy AX/CGS actually REPORTED suppresses the poll's. Any
        // recent AX event used to — but a display removal fires moved/resized
        // for every relocated window, so windows that dropped out then were
        // forgotten silently: no destroy, caches kept, per-window observers
        // kept, and the window came back later as a phantom "create".
        let destroys = Self.pollDestroyActions(
            destroyed: diff.destroyed,
            destroyReported: { WindowsAXObserver.shared.destroyReportedRecently(wid: CGWindowID($0), within: 12.0) })
        for snap in destroys {
            onDestroy?(snap)
            missedDestroyed += 1
        }
        for (snap, oldTitle) in diff.titleChanged where !axCoveredRecently(wid: CGWindowID(snap.id)) {
            onTitleChange?(snap, oldTitle)
            missedTitled += 1
        }

        let total = missedCreated + missedDestroyed + missedTitled
        if total > 0 {
            log("win-poll missed-by-ax: +\(missedCreated) -\(missedDestroyed) ~\(missedTitled) (10s safety backstop caught what AX did not fire)")
        }
        sweepPerWindowCoverage(rows: rows, listed: Set(now.keys))
        WindowDebug.log("poll tick: total seen=\(diff.created.count + diff.destroyed.count + diff.titleChanged.count) missed-by-ax=\(total)")
        // Listener-fires sensor for the CGS codes: per-code counts since
        // launch, piggybacked on the poll's cadence. Codes stuck at zero
        // (806/807 need the interest list; 1325/1326 are build-dependent)
        // mean AX is carrying that signal alone on this macOS.
        let cgsCounts = WindowEvents.fireCountsSnapshot()
        if !cgsCounts.isEmpty {
            let summary = cgsCounts.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }.joined(separator: " ")
            WindowDebug.log("cgs fire counts: \(summary)")
        }
        if OverlayEventFollow.enabled {
            let f = OverlayEventFollow.statsSnapshot()
            WindowDebug.log("overlay-events: main=\(f.onMain) off-main=\(f.offMain) for-targets=\(f.forTargets) stepped=\(f.steppedOnMain)")
        }
        if WindowDebug.enabled {
            let i = WindowServerIntake.statsSnapshot()
            WindowDebug.log("intake: offered=\(i.offered) merged=\(i.merged) drains=\(i.drains) max-batch=\(i.maxBatch)")
        }

        // Housekeeping piggybacked on the poll tick: lastAxFire only needs
        // ~12s of history for the missed-by-ax gate; without pruning it
        // accumulates one entry per wid ever seen for the daemon's lifetime.
        WindowsAXObserver.shared.pruneAxFireLog(olderThan: 60)

        snapshot = now
    }

    /// Pure classification for the poll's created diffs — which snaps get
    /// the full announcement (bang + fanout pump via onCreate) and whether
    /// a channel-only pump nudge is owed for the suppressed rest.
    /// Suppression means AX or a prior announcement already covered the
    /// wid, so re-announcing would double-fire bangs — but a wid ENTERING
    /// the poll snapshot still means Windows.all() gained a window stacks
    /// may not have seen (a healed addressability verdict resurfaces
    /// exactly this way, inside the ax-covered window of the very
    /// minimize/deminimize events that poisoned it). tick() absorbs the
    /// diff into its snapshot either way, so a suppressed create fires
    /// exactly once — without the nudge the reappearance would wait on the
    /// next ambient pump, unbounded on an idle system. pushFn's JSON dedup
    /// makes the nudge a no-op when stacks are already current.
    static func pollCreateActions(created: [Snap],
                                  axCovered: (Int) -> Bool,
                                  announced: (Int) -> Bool) -> (announce: [Snap], pumpNudge: Bool) {
        let announce = created.filter { !axCovered($0.id) && !announced($0.id) }
        return (announce, announce.count < created.count)
    }

    /// CGWindowList can read empty for a moment (wake, display
    /// reconfiguration). Diffing that would report every window destroyed
    /// and then re-created; real closes still arrive through AX/CGS.
    static func shouldSkipTick(previousCount: Int, currentCount: Int) -> Bool {
        currentCount == 0 && previousCount > 0
    }

    /// Pure classification for the poll's destroyed diffs: fire every one
    /// except those AX or CGS already reported as destroyed (their
    /// onDestroy already ran).
    static func pollDestroyActions(destroyed: [Snap], destroyReported: (Int) -> Bool) -> [Snap] {
        destroyed.filter { !destroyReported($0.id) }
    }

    /// Pure diff for testability — given two snapshots, return the
    /// (created, destroyed, titleChanged) tuples. Decoupled from `tick()`
    /// so the diff math can be unit-tested without instantiating a Timer.
    static func diff(prev: [Int: Snap], next: [Int: Snap])
        -> (created: [Snap], destroyed: [Snap], titleChanged: [(Snap, String)])
    {
        var created: [Snap] = []
        var destroyed: [Snap] = []
        var titleChanged: [(Snap, String)] = []
        for (id, info) in next {
            if let old = prev[id] {
                if old.title != info.title {
                    titleChanged.append((info, old.title))
                }
            } else {
                created.append(info)
            }
        }
        for (id, info) in prev where next[id] == nil {
            destroyed.append(info)
        }
        return (created, destroyed, titleChanged)
    }

    /// True if WindowsAXObserver fired for this wid within ~12s (one
    /// tick + small safety margin). 12s not 10s because AX fires a
    /// fraction of a second before the action lands in CGWindowList —
    /// the poll on its next tick would otherwise re-fire the same event.
    private func axCoveredRecently(wid: CGWindowID) -> Bool {
        WindowsAXObserver.shared.axFiredRecently(wid: wid, within: 12.0)
    }

    /// Whether the poll has already seen this window on a previous tick —
    /// the "is this window actually new?" oracle for the CGS 1325 create
    /// trigger. A space-MOVE fires 1325 too; a wid the poll has snapshotted
    /// is a move, not a create, even when AX never installed observers on
    /// it (unobservable apps).
    func knownWindow(_ id: Int) -> Bool {
        snapshot[id] != nil
    }

    /// JSON-able detail dict for bang dispatch.
    static func detail(_ s: Snap) -> [String: Any] {
        [
            "id":    s.id,
            "pid":   s.pid,
            "app":   s.app,
            "title": s.title,
            "frame": [
                "x": Int(s.frame.origin.x), "y": Int(s.frame.origin.y),
                "w": Int(s.frame.size.width), "h": Int(s.frame.size.height)
            ]
        ]
    }

    /// The `sd.window.created` detail: `detail` plus `mouseDown`, whether
    /// the left button was held when the window was announced. A window
    /// that appears mid-drag is usually a tab being dragged out of another
    /// window rather than a new one.
    static func createdDetail(_ s: Snap, mouseDown: Bool) -> [String: Any] {
        var d = detail(s)
        d["mouseDown"] = mouseDown
        return d
    }

    /// Attach per-window observers to listed windows that have none (see
    /// PerWindowCoverage). Logged plainly: every hit means some attach
    /// path dropped a window, and until now it was deaf to minimize,
    /// deminimize, moved, and resized.
    private func sweepPerWindowCoverage(rows: [[String: Any]], listed: Set<Int>) {
        coverageGate.retain(ids: listed)
        let ax = WindowsAXObserver.shared
        let uncovered = PerWindowCoverage.uncovered(rows: rows, covered: { ax.pidFor(wid: CGWindowID($0)) != nil })
        let now = CFAbsoluteTimeGetCurrent()
        var attempted: [Int] = []
        for w in uncovered where coverageGate.shouldAttempt(id: w.id, now: now) {
            ax.ensurePerWindow(pid: pid_t(w.pid), wid: CGWindowID(w.id))
            attempted.append(w.id)
        }
        if !attempted.isEmpty {
            log("win-poll uncovered-by-ax: \(attempted) had no per-window observers (no minimize/move/resize events); attaching")
        }
    }

    private func current(_ rows: [[String: Any]] = Windows.all()) -> [Int: Snap] {
        var out: [Int: Snap] = [:]
        for raw in rows {
            guard let id = raw["id"] as? Int else { continue }
            let frameDict = raw["frame"] as? [String: Int] ?? [:]
            out[id] = Snap(
                id: id,
                pid: raw["pid"] as? Int ?? 0,
                app: raw["app"] as? String ?? "",
                title: raw["title"] as? String ?? "",
                frame: CGRect(
                    x: frameDict["x"] ?? 0, y: frameDict["y"] ?? 0,
                    width: frameDict["w"] ?? 0, height: frameDict["h"] ?? 0
                )
            )
        }
        return out
    }
}

// MARK: - WindowsPumpRetry: bounded re-pump decision for sd.windows.all

/// Pure decision core for the create/destroy → `sd.windows.all` consistency
/// loop. AX fires within one runloop tick of the action; CGWindowList (the
/// source `Windows.all()` reads) lags by ~50–500ms. Pushing the channel the
/// moment AX fires therefore often ships a snapshot that does NOT yet
/// reflect the event — a stack diffing the snapshot sees no change, and the
/// 10s safety poll then SUPPRESSES its own re-fire because `lastAxFire` is
/// fresh, so the event is silently absorbed (the windowscape "created but
/// never tiled / tiled ~10s late" symptom). The fix: verify the snapshot
/// reached the expected state and re-push on a short ladder until it does.
/// Ladder exhaustion logs via WindowDebug — that's CG telling us something
/// is genuinely different about this window (non-zero layer, etc.).
enum WindowsPumpRetry {
    /// Successive verify delays. Cumulative ≈ 900ms — covers the observed
    /// 50–500ms CGWindowList lag with margin, without drifting toward
    /// poll-as-primary.
    static let delays: [TimeInterval] = [0.15, 0.3, 0.45]

    enum Expectation: Equatable {
        case present(Int)  // created → wid must appear in the snapshot
        case absent(Int)   // destroyed → wid must be gone from the snapshot
    }

    static func satisfied(ids: Set<Int>, expectation: Expectation) -> Bool {
        switch expectation {
        case .present(let id): return ids.contains(id)
        case .absent(let id):  return !ids.contains(id)
        }
    }

    /// Delay before verify attempt `attempt` (0-based); nil once the ladder
    /// is exhausted.
    static func delay(attempt: Int) -> TimeInterval? {
        guard attempt >= 0 && attempt < delays.count else { return nil }
        return delays[attempt]
    }
}

// MARK: - WindowLifecycleFanout: created-bang gating on CGWindowList agreement

/// Defers the `sd.window.created` fan-out until `Windows.all()` actually
/// lists the new wid (bounded by the WindowsPumpRetry ladder), then pushes
/// the channel BEFORE firing the bang. Ordering matters: stacks hydrate
/// their window model from the all-push and react to the bang — a bang that
/// arrives ahead of a snapshot containing the window is a no-op diff on the
/// stack side, and nothing re-triggers it (the late all-push only updates
/// state). Exactly-once bang semantics are preserved: on ladder exhaustion
/// we fire anyway (late beats never) and leave a WindowDebug breadcrumb.
/// Check-and-mark ledger for create announcements. Pure so the dedup
/// contract is headless-testable; owned by WindowLifecycleFanout — the ONE
/// point all three announcers (AX create, CGS 1325 fast path, 10s poll)
/// already funnel through. Scattered per-announcer check+mark drops creates
/// (one announcer consults a map another path polluted), and a fourth
/// announcer added later can't forget a protocol the funnel owns.
struct CreateAnnouncementLedger {
    /// One tick of the safety poll + margin — same window the poll's
    /// missed-by-ax gate uses.
    static let ttl: Double = 12.0
    private var announced: [Int: Double] = [:]

    /// True exactly once per window per TTL; marks on the way through.
    /// Prunes expired entries opportunistically (creates are rare; the
    /// map is bounded by the 12s create rate).
    mutating func shouldAnnounce(id: Int, now: Double) -> Bool {
        announced = announced.filter { now - $0.value < Self.ttl }
        if announced[id] != nil { return false }
        announced[id] = now
        return true
    }

    func announcedRecently(id: Int, now: Double) -> Bool {
        guard let ts = announced[id] else { return false }
        return now - ts < Self.ttl
    }
}

/// What the created fan-out drives: the sd.windows.all push and bang
/// delivery to every stack.
protocol WindowLifecycleHost: AnyObject {
    func pumpWindowsListForAllStacks()
    @discardableResult func bang(name: String, detail: [String: Any]) -> Int
}

extension StackHost: WindowLifecycleHost {}

enum WindowLifecycleFanout {
    private static var announcements = CreateAnnouncementLedger()

    /// Read-only view for the poll's missed-by-ax drift counter — the poll
    /// checks before calling onCreate so an already-announced create
    /// neither double-fires nor inflates the "AX missed this" log.
    static func announcedRecently(id: Int) -> Bool {
        announcements.announcedRecently(id: id, now: Date().timeIntervalSince1970)
    }

    /// `mouseDown` is the left-button state for the detail; nil samples it
    /// now, at the announcement, and retries carry that sample.
    static func fireCreated(host: WindowLifecycleHost?, snap: WindowsLifecycleObserver.Snap,
                            attempt: Int = 0, mouseDown: Bool? = nil) {
        // Single-owner dedup at the funnel: announcers classify ("is this
        // a create at all?"); WHETHER it was already announced is decided
        // here, once. Retries (attempt > 0) are the same announcement.
        if attempt == 0,
           !announcements.shouldAnnounce(id: snap.id, now: Date().timeIntervalSince1970) {
            WindowDebug.log("created fan-out: wid=\(snap.id) already announced — deduped")
            return
        }
        let held = mouseDown ?? Mouse.isLeftButtonDown()
        let ids = Set(Windows.all().compactMap { $0["id"] as? Int })
        if WindowsPumpRetry.satisfied(ids: ids, expectation: .present(snap.id)) {
            dispatch(host: host, snap: snap, attempt: attempt, mouseDown: held)
            return
        }
        guard let delay = WindowsPumpRetry.delay(attempt: attempt) else {
            WindowDebug.log("created fan-out: wid=\(snap.id) (\(snap.app)) never appeared in Windows.all() after \(attempt) retries — firing anyway")
            dispatch(host: host, snap: snap, attempt: attempt, mouseDown: held)
            return
        }
        WindowDebug.log("created fan-out: wid=\(snap.id) not in Windows.all() yet — retry in \(Int(delay * 1000))ms")
        // Strong capture of `host` is fine: the chain is bounded (<1s) and
        // the StackHost lives for the daemon's lifetime anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            WindowLifecycleFanout.fireCreated(host: host, snap: snap, attempt: attempt + 1, mouseDown: held)
        }
    }

    private static func dispatch(host: WindowLifecycleHost?, snap: WindowsLifecycleObserver.Snap,
                                 attempt: Int, mouseDown: Bool) {
        WindowDebug.log("created fan-out: wid=\(snap.id) dispatch (attempt=\(attempt))")
        host?.pumpWindowsListForAllStacks()
        host?.bang(name: "sd.window.created",
                   detail: WindowsLifecycleObserver.createdDetail(snap, mouseDown: mouseDown))
    }
}
