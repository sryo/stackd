import CoreGraphics
import Foundation

// Event-driven overlay follow: routing of window-server frame events
// (CGS 806/807) to the overlays tracking the moved window.

/// What the main thread last applied for one overlay, readable from the
/// thread SkyLight delivers events on. `panelWID` 0 = no window-server
/// window yet; `targetSize` is the target size the panel was last fitted to.
struct OverlayFollowEntry: Equatable {
    var wid: UInt32
    var panelWID: UInt32
    var outset: CGFloat
    var targetSize: CGSize
    var visible: Bool
    /// The target is under a daemon animation and the panel follows the
    /// commanded frame; window-server frame events for it are ignored.
    var commanded: Bool = false
}

enum OverlayFollowAction: Equatable {
    case ignore
    /// Window-server move of the panel to this CGS top-left origin, no
    /// reorder: the panel is visible and already above its target.
    case moveNow(CGPoint)
    /// Anything that can touch AppKit or the WebView — resize, visibility,
    /// an unreadable target — runs as a full step on main.
    case stepOnMain
}

enum OverlayFollowRoute {
    /// The target wid of a 806/807, nil for any other event.
    static func frameEventWID(_ event: CGSDecodedWindowEvent) -> UInt32? {
        switch event {
        case .moved(let wid), .resized(let wid): return wid
        default: return nil
        }
    }

    /// `bounds` is SLSGetWindowBounds of the target, read after the event.
    static func action(for event: CGSDecodedWindowEvent, entry: OverlayFollowEntry,
                       bounds: CGRect?) -> OverlayFollowAction {
        guard let wid = frameEventWID(event), wid == entry.wid, !entry.commanded else { return .ignore }
        guard case .moved = event,
              entry.visible, entry.panelWID != 0,
              let b = bounds,
              abs(b.width - entry.targetSize.width) < 0.5,
              abs(b.height - entry.targetSize.height) < 0.5 else { return .stepOnMain }
        return .moveNow(CGPoint(x: b.minX - entry.outset, y: b.minY - entry.outset))
    }
}

// MARK: - Window-server event follow

/// Attached overlays follow their target on CGS 806 (moved) / 807
/// (resized) as the window server posts them, instead of on the next
/// display-link tick. The vsync tick stays armed as the backstop; this path
/// only gets there first. `STACKD_OVERLAY_EVENTS=0` turns it off: 806/807
/// stay unregistered, no interest list is set, and overlays follow on the
/// tick alone.
///
/// 806/807 only fire for wids on the connection's interest list, which
/// WindowEvents keeps at every AX-tracked window plus every overlay target
/// (see `WindowFrameInterest`). Events for windows no overlay targets are
/// counted and dropped here.
///
/// Threading: the target set is main-thread state mirrored into the
/// lock-protected `targetWIDs`/`entries`, so an event delivered off main can
/// move a visible panel at the window server directly. AppKit state
/// (`panel.frame`, the tick's lastFrame) is only touched by the main-thread
/// step each event also queues, which resyncs it; the origin moved off main
/// is kept in `applied` so that step doesn't send the same move again.
/// The main-thread step rides WindowServerIntake, which merges events per
/// wid and drains once per burst.
enum OverlayEventFollow {
    static func flagEnabled(_ env: [String: String]) -> Bool {
        env["STACKD_OVERLAY_EVENTS"] != "0"
    }

    static let enabled = flagEnabled(ProcessInfo.processInfo.environment)

    // Main thread.
    private static var targets = OverlayFollowTargets<ObjectIdentifier>()

    private static let lock = NSLock()
    private static var targetWIDs: Set<UInt32> = []
    private static var entries: [ObjectIdentifier: OverlayFollowEntry] = [:]
    private static var applied: [ObjectIdentifier: CGPoint] = [:]
    private static var stats = Stats()
    private static var threadLogged = false

    struct Stats {
        var onMain = 0
        var offMain = 0
        var forTargets = 0
        var movedOffMain = 0
        var steppedOnMain = 0
    }

    static func statsSnapshot() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    /// Current overlay target wids, ascending. Main thread.
    static var targetList: [UInt32] { targets.wids }

    /// Attach or retarget. Main thread.
    static func track(_ handle: OverlayHandle) {
        guard enabled else { return }
        if targets.set(ObjectIdentifier(handle), wid: UInt32(handle.targetWID)) { targetsChanged() }
    }

    /// Detach. Main thread.
    static func untrack(_ handle: OverlayHandle) {
        guard enabled else { return }
        let key = ObjectIdentifier(handle)
        lock.lock(); entries[key] = nil; applied[key] = nil; lock.unlock()
        if targets.remove(key) { targetsChanged() }
    }

    /// The target window is gone. Main thread.
    static func dropTarget(wid: CGWindowID) {
        guard enabled else { return }
        let w = UInt32(wid)
        lock.lock()
        for (key, entry) in entries where entry.wid == w {
            entries[key] = nil
            applied[key] = nil
        }
        lock.unlock()
        if targets.drop(wid: w) { targetsChanged() }
    }

    /// Record what the tick just applied, for an overlay still following
    /// that wid; a detached or destroyed-target overlay keeps no entry.
    /// Main thread.
    static func publish(_ handle: OverlayHandle, _ entry: OverlayFollowEntry) {
        guard enabled else { return }
        let key = ObjectIdentifier(handle)
        let live = targets.wid(for: key) == entry.wid
        lock.lock(); entries[key] = live ? entry : nil; lock.unlock()
    }

    /// The CGS origin the event path moved `handle`'s panel to since the
    /// last call, if any. Main thread.
    static func takeApplied(_ handle: OverlayHandle) -> CGPoint? {
        guard enabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        return applied.removeValue(forKey: ObjectIdentifier(handle))
    }

    private static func targetsChanged() {
        let wids = Set(targets.wids)
        lock.lock(); targetWIDs = wids; lock.unlock()
        WindowEvents.scheduleFrameInterestRefresh()
    }

    /// A decoded 806/807, on whatever thread SkyLight delivered it.
    static func handle(_ event: CGSDecodedWindowEvent) {
        guard enabled, let wid = OverlayFollowRoute.frameEventWID(event) else { return }
        let onMain = Thread.isMainThread
        lock.lock()
        if onMain { stats.onMain += 1 } else { stats.offMain += 1 }
        let logThread = !threadLogged
        threadLogged = true
        let isTarget = targetWIDs.contains(wid)
        if isTarget { stats.forTargets += 1 }
        let mine = onMain || !isTarget ? [] : entries.filter { $0.value.wid == wid }
        lock.unlock()
        if logThread {
            log("overlay-events: first 806/807 delivered \(onMain ? "on main" : "off main (\(Thread.current))")")
        }
        // Every listed window's event still reaches main, where
        // sd.window.resizing reads it; only targets move panels here.
        if isTarget && !mine.isEmpty {
            let bounds = Overlay.bounds(of: CGWindowID(wid))
            var moved: [ObjectIdentifier: CGPoint] = [:]
            for (key, entry) in mine {
                if case .moveNow(let origin) = OverlayFollowRoute.action(for: event, entry: entry, bounds: bounds),
                   Overlay.serverMove(panelWID: entry.panelWID, cgsOrigin: origin) {
                    moved[key] = origin
                }
            }
            lock.lock()
            stats.movedOffMain += moved.count
            // Only for overlays still listed: a detach or destroy since the
            // snapshot above already dropped theirs.
            for (key, origin) in moved where entries[key] != nil { applied[key] = origin }
            lock.unlock()
        }
        WindowServerIntake.post(.window(event))
    }

    static func countStep() {
        lock.lock(); stats.steppedOnMain += 1; lock.unlock()
    }
}
