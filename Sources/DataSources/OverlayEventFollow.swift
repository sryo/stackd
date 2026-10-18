import CoreGraphics
import Foundation

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
/// Threading: the notify proc is registered on the main connection, whose
/// events SkyLight delivers on the main thread. Each event rides
/// WindowServerIntake, which merges events per wid and drains once per
/// burst into `Overlay.followFrameEvent`, where the tracking overlays step.
/// The counters record the delivering thread, so a delivery off main would
/// show in the log rather than go unnoticed.
enum OverlayEventFollow {
    static func flagEnabled(_ env: [String: String]) -> Bool {
        env["STACKD_OVERLAY_EVENTS"] != "0"
    }

    static let enabled = flagEnabled(ProcessInfo.processInfo.environment)

    // Main thread.
    private static var targets = OverlayFollowTargets<ObjectIdentifier>()

    // Guards the target mirror and the counters, which `handle` reads and
    // writes on whatever thread delivered the event.
    private static let lock = NSLock()
    private static var targetWIDs: Set<UInt32> = []
    private static var stats = Stats()
    private static var threadLogged = false

    struct Stats {
        var onMain = 0
        var offMain = 0
        var forTargets = 0
        /// Panels moved at the window server before the main-thread step.
        /// Always 0: frame events only move panels from that step.
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
        if targets.remove(ObjectIdentifier(handle)) { targetsChanged() }
    }

    /// The target window is gone. Main thread.
    static func dropTarget(wid: CGWindowID) {
        guard enabled else { return }
        if targets.drop(wid: UInt32(wid)) { targetsChanged() }
    }

    private static func targetsChanged() {
        let wids = Set(targets.wids)
        lock.lock(); targetWIDs = wids; lock.unlock()
        WindowEvents.scheduleFrameInterestRefresh()
    }

    /// The target wid of a 806/807, nil for any other event.
    static func frameEventWID(_ event: CGSDecodedWindowEvent) -> UInt32? {
        switch event {
        case .moved(let wid), .resized(let wid): return wid
        default: return nil
        }
    }

    /// A decoded 806/807. Every listed window's event reaches main through
    /// the intake, where sd.window.resizing reads it and overlays on that
    /// target step.
    static func handle(_ event: CGSDecodedWindowEvent) {
        guard enabled, let wid = frameEventWID(event) else { return }
        let onMain = Thread.isMainThread
        lock.lock()
        if onMain { stats.onMain += 1 } else { stats.offMain += 1 }
        let logThread = !threadLogged
        threadLogged = true
        if targetWIDs.contains(wid) { stats.forTargets += 1 }
        lock.unlock()
        if logThread {
            log("overlay-events: first 806/807 delivered \(onMain ? "on main" : "off main (\(Thread.current))")")
        }
        WindowServerIntake.post(.window(event))
    }

    static func countStep() {
        lock.lock(); stats.steppedOnMain += 1; lock.unlock()
    }
}
