import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// =====================================================================
// MARK: - CGS window events
// =====================================================================

// Window-level CGS notifications via SkyLight private SPI. AX stays
// co-primary; CGS adds window-server latency (~1-5ms) and covers what AX
// can't see:
//   - 808 — window reordered (z-order). AX has no reordered notification.
//           LOAD-BEARING: Overlay's z-order repair keys off it.
//   - 804 — window destroyed. Belt-and-suspenders with AX's
//           kAXUIElementDestroyedNotification (yabai registers it on Tahoe).
//   - 1325/1326 — window added/removed on a space. Fire WITHOUT any
//           interest list. 1325 is the FAST create trigger (fires before
//           slow AX trees publish) and the space-move signal for known
//           windows.
//   - 1508: focus by mouse click, within one app too. Its payload is
//            empty, so it names no app; it is a bang, not an activation
//            trigger.
//
// Per-connection registration (`SLSRegisterConnectionNotifyProc`, yabai's
// pattern in `src/yabai.c`).
//
// 806/807 (moved/resized) are registered too, which needs an interest
// list (`SLSRequestNotificationsForWindows`): once a connection sets one,
// the window server posts 806/807 AND 808 only for the listed windows. The
// list therefore holds every AX-tracked window plus every overlay target
// (`WindowFrameInterest`), sorted, re-issued once per burst on create /
// destroy / attach / retarget / detach. OmniWM runs the same shape
// (806/807/808 on the main cid, the full sorted managed-window list).
// A list narrowed to a few windows is what made 808 look silenced by
// 806/807: raises of unlisted windows post nothing. With the full list,
// 808 fires for raises again and overlays follow at window-server time
// (OverlayEventFollow in Overlay.swift). OverlayRepinPolicy's cadence
// stays the z-order backstop for any window the list misses. The same
// 806/807 of AX-tracked windows feed sd.window.resizing
// (WindowResizeObserver in WindowResizing.swift).
//
// STACKD_OVERLAY_EVENTS=0 is the kill switch: 806/807 stay unregistered
// and no interest list is set, so 808 fires for every window and
// overlays follow on their vsync tick alone.
//
// 1322 (title) is not registered; AX titleChanged covers it.
//
// The per-code fire counters (logged from the 10s poll tick) are the
// standing verification that registered codes keep firing across macOS
// bumps; codes stuck at zero degrade gracefully to AX-only coverage.
//
// To rediscover IDs after a macOS bump: launch with STACKD_CGS_DEBUG=1
// and the existing debug loop logs every event in [700, 2000).

private enum SkyLightWindowEvents {
    // SLSRegisterConnectionNotifyProc(cid, callback, eventType, context).
    // Same wire format as the SpacesObserver in Spaces.swift uses
    // (`SkyLightSpaces.RegisterNotifyProcFn`). Per-connection so it scopes
    // to our SkyLight cid like every other reliable tiler does — yabai
    // (`src/yabai.c:322-334`) is the reference.
    typealias CGSConnectionCallback = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
    typealias RegisterNotifyProcFn  = @convention(c) (Int32, CGSConnectionCallback, UInt32, UnsafeMutableRawPointer?) -> Int32
    // SLSRequestNotificationsForWindows(cid, wids, count): the interest
    // list. Replaces the connection's list in full on every call.
    typealias RequestNotificationsFn = @convention(c) (Int32, UnsafePointer<UInt32>?, Int32) -> Int32

    static let registerNotifyProc: RegisterNotifyProcFn? = SkyLight.sym("SLSRegisterConnectionNotifyProc")
    static let requestNotifications: RequestNotificationsFn? = SkyLight.sym("SLSRequestNotificationsForWindows")
}

// CGS window event IDs we register — yabai's canonical set plus the
// per-window codes OmniWM proved live on Tahoe (given an interest list):
//   804  — window destroyed       (payload: uint32 wid at offset 0)
//   806  — window moved           (uint32 wid; needs interest list)
//   807  — window resized         (uint32 wid; needs interest list)
//   808  — window reordered       (uint32 wid)
//   1322 — window title changed   (uint32 wid; needs interest list)
//   1325 — window added to space  (uint64 spaceID @0 + uint32 wid @8;
//                                  fires at window-server latency — the
//                                  fast create trigger AND the space-move
//                                  signal for known windows)
//   1326 — window removed from space (same payload; destroy is covered by
//                                  804, space-moves by 1325 on the new
//                                  space — counted, not routed)
//   1327 — window animation began (payload is a counter, not a wid; the
//                                  genie into the Dock posts it ~25ms in,
//                                  long before AX reports the minimize)
//   1508 (focused by mouse)       (empty payload on macOS 27, so no pid:
//                                  fires on mouse clicks, within one app
//                                  too, and lands within ~12 ms of
//                                  didActivateApplication, on either
//                                  side, when it does switch apps.
//                                  Surfaced as sd.window.focusedByMouse;
//                                  activation stays on NSWorkspace)
//
// Probe-only codes, named per CGSInternal's CGSNotificationType list. They
// are counted and, under STACKD_CGS_DEBUG, logged with their payload's
// leading words; nothing consumes them. On macOS 27 only 811 fires (len 4,
// the new window's wid as the only word, at window creation). The others
// never reach the notify proc, not even through the [700, 2000) debug
// catch-all, across window create/close/minimize and user edge drags —
// so the drag codes can't bracket a resize and sd.window.resizing keeps
// its mouse-button gate:
//   802  — window ordered in
//   803  — window ordered out
//   809  — window geometry did change
//   811  — window did create
//   1400 — workspace will change
//   1411 — window drag did start
//   1412 — window drag did end
//   1413 — window drag will end
private let kSDWindowClosed:         UInt32 = 804
private let kSDWindowMoved:          UInt32 = 806
private let kSDWindowResized:        UInt32 = 807
private let kSDWindowReordered:      UInt32 = 808
private let kSDWindowTitleChanged:   UInt32 = 1322
private let kSDSpaceWindowCreated:   UInt32 = 1325
private let kSDSpaceWindowDestroyed: UInt32 = 1326
private let kSDWindowAnimationBegan: UInt32 = 1327
private let kSDWindowFocusedByMouse: UInt32 = 1508

/// Probe-only codes and their CGSInternal names.
let kSDProbeEventNames: [UInt32: String] = [
    802: "windowOrderedIn",
    803: "windowOrderedOut",
    809: "windowGeometryDidChange",
    811: "windowDidCreate",
    1400: "workspaceWillChange",
    1411: "windowDragDidStart",
    1412: "windowDragDidEnd",
    1413: "windowDragWillEnd",
]

/// Decoded CGS window event. Pure decode so the offset arithmetic is
/// headless-testable — payload offsets per OmniWM's CGSEventObserver.
enum CGSDecodedWindowEvent: Equatable {
    case destroyed(wid: UInt32)
    case moved(wid: UInt32)
    case resized(wid: UInt32)
    case reordered(wid: UInt32)
    case titleChanged(wid: UInt32)
    case spaceWindowCreated(wid: UInt32, spaceID: UInt64)
    case spaceWindowDestroyed(wid: UInt32, spaceID: UInt64)
    case animationBegan
    case frontmostByMouse
    /// A probe-only code: its leading payload words (little-endian uint32,
    /// at most `probeWordLimit`), since the layout is not known yet.
    case probe(code: UInt32, words: [UInt32])
    case ignored
    case malformed
}

enum CGSWindowEventDecoder {
    static let probeWordLimit = 4

    static func decode(eventType: UInt32, data: UnsafeRawPointer?, length: Int) -> CGSDecodedWindowEvent {
        func wid(at offset: Int) -> UInt32? {
            guard let data = data, length >= offset + 4 else { return nil }
            return data.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        func space(at offset: Int) -> UInt64? {
            guard let data = data, length >= offset + 8 else { return nil }
            return data.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        }
        switch eventType {
        case kSDWindowClosed:        return wid(at: 0).map { .destroyed(wid: $0) } ?? .malformed
        case kSDWindowMoved:         return wid(at: 0).map { .moved(wid: $0) } ?? .malformed
        case kSDWindowResized:       return wid(at: 0).map { .resized(wid: $0) } ?? .malformed
        case kSDWindowReordered:     return wid(at: 0).map { .reordered(wid: $0) } ?? .malformed
        case kSDWindowTitleChanged:  return wid(at: 0).map { .titleChanged(wid: $0) } ?? .malformed
        case kSDSpaceWindowCreated:
            guard let s = space(at: 0), let w = wid(at: 8) else { return .malformed }
            return .spaceWindowCreated(wid: w, spaceID: s)
        case kSDSpaceWindowDestroyed:
            guard let s = space(at: 0), let w = wid(at: 8) else { return .malformed }
            return .spaceWindowDestroyed(wid: w, spaceID: s)
        case kSDWindowAnimationBegan: return .animationBegan
        case kSDWindowFocusedByMouse: return .frontmostByMouse
        case let code where kSDProbeEventNames[code] != nil:
            let count = data == nil ? 0 : min(max(length, 0) / 4, probeWordLimit)
            return .probe(code: code, words: (0..<count).compactMap { wid(at: $0 * 4) })
        default:                      return .ignored
        }
    }
}

// The shared callback. SkyLight invokes us off the main thread; we count
// the fire (the "does this code actually fire on this macOS?" sensor the
// poll tick logs), decode, then post to WindowServerIntake, whose one drain
// per burst dispatches on main before touching AppDelegate.shared / host
// so bang dispatch stays on the runloop it was built on.
/// The per-window interest list for the overlay-events path: every
/// AX-tracked window plus every overlay target (a target AX can't observe
/// still needs its frame events), as one sorted, duplicate-free list.
/// With a list set, window-server events like 808 only fire for listed
/// windows, so the list is kept as wide as the tracked set rather than
/// narrowed to the overlay targets.
enum WindowFrameInterest {
    static func list(tracked: [UInt32], targets: [UInt32]) -> [UInt32] {
        Array(Set(tracked).union(targets)).sorted()
    }
}

private let windowEventsCallback: SkyLightWindowEvents.CGSConnectionCallback = { eventType, data, dataLen, _, _ in
    WindowEvents.countFire(eventType)
    let event = CGSWindowEventDecoder.decode(
        eventType: eventType, data: data.map { UnsafeRawPointer($0) }, length: dataLen)
    WindowDebug.log("cgs evt=\(eventType) → \(event)")
    // Non-actionable events (1326 counted-only, 1322, ignored/malformed)
    // end here — no main-queue hop for a `break`. 806/807 only reach us
    // when OverlayEventFollow registered them; it moves overlay panels on
    // this thread, then posts them to the intake.
    switch event {
    case .moved, .resized:
        OverlayEventFollow.handle(event)
        return
    case .probe(let code, let words):
        if CGSProbe.logging {
            log("cgs probe: \(CGSProbe.describe(code: code, words: words, length: dataLen))")
        }
        return
    case .spaceWindowDestroyed, .titleChanged, .ignored, .malformed:
        return
    default:
        WindowServerIntake.post(.window(event))
    }
}

/// Log formatting for the probe-only codes (STACKD_CGS_DEBUG).
enum CGSProbe {
    static let logging = ProcessInfo.processInfo.environment["STACKD_CGS_DEBUG"] != nil

    /// `1411 windowDragDidStart len=8 words=[0x00001a2b 0x00000000]`
    static func describe(code: UInt32, words: [UInt32], length: Int) -> String {
        let name = kSDProbeEventNames[code] ?? "unknown"
        let hex = words.map { String(format: "0x%08x", $0) }.joined(separator: " ")
        return "\(code) \(name) len=\(length) words=[\(hex)]"
    }
}

// Debug logger: prints every event ID + first 32 bytes of payload to stderr.
// Active only when STACKD_CGS_DEBUG=1. Used to verify event-ID mappings after
// a macOS version bump. Connection-notify shape matches yabai's loop.
private let debugWindowEventsCallback: SkyLightWindowEvents.CGSConnectionCallback = { event, data, dataLen, _, _ in
    var hex = ""
    if let data = data, dataLen > 0 {
        let lim = min(dataLen, 32)
        for i in 0..<lim {
            hex += String(format: "%02x ", data.advanced(by: i).load(as: UInt8.self))
        }
    }
    log("cgs: event=\(event) len=\(dataLen) [\(hex)]")
}

enum WindowEvents {
    private static var cgsRegistered = false

    /// Install the CGS callbacks. Idempotent; safe to call from
    /// AppDelegate. Registrations live for the lifetime of the process by
    /// choice — SLSRemoveConnectionNotifyProc does exist (OmniWM binds
    /// it), but there's nothing to tear down: the callback no-ops cheaply
    /// when nothing consumes it.
    static func install() {
        guard !cgsRegistered, let reg = SkyLightWindowEvents.registerNotifyProc else { return }
        let cid = SkyLight.cid
        for evt in [kSDWindowClosed, kSDWindowReordered,
                    kSDSpaceWindowCreated, kSDSpaceWindowDestroyed,
                    kSDWindowAnimationBegan, kSDWindowFocusedByMouse] {
            _ = reg(cid, windowEventsCallback, evt, nil)
        }
        // Probe-only codes: a notify proc per code, no interest list — the
        // list set for 806/807/808 is untouched.
        for evt in kSDProbeEventNames.keys.sorted() {
            _ = reg(cid, windowEventsCallback, evt, nil)
        }
        if OverlayEventFollow.enabled {
            for evt in [kSDWindowMoved, kSDWindowResized] {
                _ = reg(cid, windowEventsCallback, evt, nil)
            }
            log("overlay-events: 806/807 registered; interest list = AX-tracked windows + overlay targets (STACKD_OVERLAY_EVENTS=0 disables)")
            DispatchQueue.main.async { scheduleFrameInterestRefresh() }
        }
        // STACKD_CGS_DEBUG=1 → log every event in [700, 2000) so we can
        // rediscover IDs after a macOS shift. Mirrors JankyBorders'
        // src/events.c debug loop.
        if ProcessInfo.processInfo.environment["STACKD_CGS_DEBUG"] != nil {
            for i in UInt32(700)..<UInt32(2000) {
                _ = reg(cid, debugWindowEventsCallback, i, nil)
            }
        }
        cgsRegistered = true
    }

    // MARK: - Per-window interest list (off under STACKD_OVERLAY_EVENTS=0)

    private static var interestRefreshQueued = false
    private static var lastInterest: [UInt32]?

    /// Re-issue the interest list on the next main run-loop turn, once per
    /// burst of tracked-window / overlay-target changes. Any thread.
    static func scheduleFrameInterestRefresh() {
        guard OverlayEventFollow.enabled else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { scheduleFrameInterestRefresh() }
            return
        }
        guard !interestRefreshQueued else { return }
        interestRefreshQueued = true
        DispatchQueue.main.async {
            interestRefreshQueued = false
            refreshFrameInterest()
        }
    }

    /// Replace the connection's interest list with WindowFrameInterest's
    /// list when it differs from the last one issued. Main thread.
    private static func refreshFrameInterest() {
        guard let req = SkyLightWindowEvents.requestNotifications, SkyLight.cid != 0 else { return }
        let wids = WindowFrameInterest.list(tracked: WindowsAXObserver.shared.trackedWIDs,
                                            targets: OverlayEventFollow.targetList)
        guard wids != lastInterest else { return }
        // Until something is listed the connection keeps no list at all.
        if wids.isEmpty && lastInterest == nil { return }
        lastInterest = wids
        let status = wids.withUnsafeBufferPointer { buf in
            req(SkyLight.cid, buf.baseAddress, Int32(buf.count))
        }
        WindowDebug.log("cgs frame interest: \(wids.count) windows (status \(status))")
    }

    // MARK: - Fire counters (listener-actually-fires sensor)

    /// Per-code fire counts, read by the 10s lifecycle poll's log line.
    /// This is the CLAUDE.md "verify the listener actually fires" gate for
    /// the newly-registered codes: if 806/807 stay at zero on some macOS
    /// build even with the interest list, the counter says so and AX
    /// remains co-primary — nothing regresses.
    private static let fireCountLock = NSLock()
    private static var fireCounts: [UInt32: Int] = [:]

    static func countFire(_ eventType: UInt32) {
        fireCountLock.lock()
        fireCounts[eventType, default: 0] += 1
        fireCountLock.unlock()
    }

    static func fireCountsSnapshot() -> [UInt32: Int] {
        fireCountLock.lock()
        defer { fireCountLock.unlock() }
        return fireCounts
    }

    /// True while a window-server animation (the genie into the Dock, and
    /// any other animation that warps a window's listed bounds) is
    /// carrying `windowID`: from the first frame it is seen warped until
    /// the frame its listed size matches its own again, or, when the
    /// animation takes it off screen, until shortly after (see
    /// `WindowAnimationWatch`). A minimize reads true ~25ms in, long before
    /// AX reports the window minimized. Main thread.
    static func isAnimating(windowID: CGWindowID) -> Bool {
        WindowAnimationObserver.shared.isAnimating(windowID: windowID)
    }

    // MARK: - Routing

    /// One drained window-server event (merged per kind + wid by
    /// WindowServerIntake). Main thread.
    static func dispatch(_ event: CGSDecodedWindowEvent) {
        guard let host = AppDelegate.shared?.host else { return }
        switch event {
        case .reordered(let wid):
            // Overlay z-order repair: if an overlay panel is pinned to
            // this window, the raise may have put the target ABOVE the
            // panel without moving it — the frame-diff short-circuit in
            // OverlayHandle.tick would then never reorder, leaving the
            // border invisible behind its own target. Event-driven
            // primary for the repin; tick's cadence is the backstop.
            Overlay.notifyWindowReordered(wid: CGWindowID(wid))
            host.bang(name: "sd.window.reordered", detail: ["id": Int(wid)])
        case .destroyed(let wid):
            // Targeted invalidation only. The previous invalidateAll()
            // nuked every pid's AX map on EVERY 804 — and 804 fires for
            // every window destroyed system-wide (tooltips, menus,
            // popovers), so the cache was being rebuilt near-constantly,
            // recreating the wid↔AXUIElement oscillation bug the
            // per-window invalidate in AppDelegate.onDestroy was built
            // to avoid. The pid can't be recovered from CGWindowList
            // (the window is already gone) — ask the AX observer's
            // per-window registry; when unknown, skip: a stale cached
            // AXUIElement is tolerated (-25204 on action) and the AX
            // destroy path does its own targeted invalidate.
            if let pid = WindowsAXObserver.shared.pidFor(wid: CGWindowID(wid)) {
                WindowsByID.invalidateCache(pid: pid, windowID: CGWindowID(wid))
            }
            WindowsAXObserver.shared.noteDestroyReported(wid: CGWindowID(wid))
            Overlay.noteTargetDestroyed(wid: CGWindowID(wid))
            WindowResizeObserver.shared.windowDestroyed(wid: CGWindowID(wid))
            scheduleFrameInterestRefresh()
            host.bang(name: "sd.window.destroyed", detail: ["id": Int(wid)])
        case .moved(let wid), .resized(let wid):
            // Any interest-listed window: overlay targets and AX-tracked
            // windows (the latter feed sd.window.resizing).
            Overlay.followFrameEvent(wid: CGWindowID(wid))
            WindowResizeObserver.shared.frameEvent(wid: CGWindowID(wid), host: host)
        case .titleChanged:
            // Not registered; AX titleChanged covers titles.
            break
        case .spaceWindowCreated(let wid, _):
            handleSpaceWindowCreated(wid: wid, host: host)
        case .spaceWindowDestroyed:
            // Destroy rides 804; a space-move fires 1325 on the NEW
            // space, which re-pushes sd.spaces.all. Counted only.
            break
        case .frontmostByMouse:
            host.bang(name: "sd.window.focusedByMouse", detail: [:])
        case .animationBegan:
            WindowAnimationObserver.shared.animationBegan()
        case .probe, .ignored, .malformed:
            break
        }
    }

    /// Positive-verdict standard-window gate for the fast-create path —
    /// the SAME rule installPerWindow's three-way subrole gate enforces
    /// for AX creates. nil (unreadable: app still constructing its AX
    /// tree, timeout under load) is NOT announceable: announcing unknowns
    /// would tile non-window hints (Arc's tab-creation hint). Unreadable
    /// windows defer to the AX create path, which retries and gates properly.
    static func fastCreateAnnounceable(subrole: String?) -> Bool {
        WindowsByID.isStandardSubrole(subrole)
    }

    /// 1325 wears two hats: for a window we already track it's a space
    /// move (re-push the spaces channel); for an unknown-but-listed window
    /// it's the FAST create trigger — the window server announces it
    /// milliseconds after creation, long before slow AX trees (Electron)
    /// publish kAXWindowCreatedNotification. The fan-out still rides the
    /// CGWindowList-consistency ladder, but it starts at window-server
    /// time instead of AX time.
    private static func handleSpaceWindowCreated(wid: UInt32, host: StackHost) {
        let cgWid = CGWindowID(wid)
        if WindowsAXObserver.shared.pidFor(wid: cgWid) != nil
            || WindowsLifecycleObserver.shared.knownWindow(Int(wid)) {
            WindowServerIntake.requestSpaces()
            return
        }
        // Snap from CGWindowList; app-level standard candidates only. Title
        // via kCGWindowName is TCC-gated (screen recording) — empty is fine,
        // AX fills it in on its own create/titleChanged pass.
        guard let info = WindowsByID.windowInfo(windowID: cgWid),
              (info[kCGWindowLayer as String] as? Int).map(Windows.isAppWindowLevel) == true,
              let pid = info[kCGWindowOwnerPID as String] as? Int
        else { return }
        // Before the subrole gate below, which needs AX for this app.
        WindowsAXObserver.shared.ensurePerWindow(pid: pid_t(pid), wid: cgWid)
        // Standard-window gate (positive verdict only): the level gate alone
        // admits app helper windows — Arc's tab-creation hint, Chromium
        // bubbles, tooltips-with-a-layer. Non-standard or not-yet-readable
        // subroles fall back to the AX create path and its retry ladder.
        // pid-hinted subrole: the id-only form would re-walk the full
        // CGWindowList just to recover the pid this dict already carries.
        guard fastCreateAnnounceable(subrole: WindowsByID.subrole(windowID: cgWid, pid: pid_t(pid))) else {
            WindowDebug.log("cgs 1325: wid=\(wid) subrole not confirmably standard — deferring to AX create path")
            return
        }
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let snap = WindowsLifecycleObserver.Snap(
            id: Int(wid),
            pid: pid,
            app: info[kCGWindowOwnerName as String] as? String ?? "",
            title: info[kCGWindowName as String] as? String ?? "",
            frame: CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        )
        WindowDebug.log("cgs 1325 create trigger: wid=\(wid) app=\(snap.app)")
        WindowLifecycleFanout.fireCreated(host: host, snap: snap)
    }
}

// =====================================================================
// MARK: - Window animations (CGS 1327)
// =====================================================================

/// Pure bookkeeping for the early "animating" signal. The window server
/// reports a minimize through AX only after the ~500ms genie, but posts
/// CGS 1327 (animation began) within a few frames. 1327 carries no window
/// id, so each one opens a watch; while it's open, a window whose
/// window-list bounds (which show the genie's warp) differ in size from
/// SkyLight's own frame (which doesn't) is animating.
///
/// The signal follows the warp frame by frame rather than holding for a
/// fixed time: it ends on the first sample where a still-listed window's
/// sizes match again (the end of a deminimize), and the watch keeps
/// sampling for as long as any window is still warped. A warped window
/// that leaves the on-screen list instead (the end of a minimize) keeps
/// reading animating for `vanishHold`, bridging the frames until SkyLight
/// reports it ordered out.
struct WindowAnimationWatch {
    /// How long a 1327 (or stackd's own minimize) samples while waiting
    /// for a warp to show.
    static let watchDuration: Double = 0.35
    /// Sampling never runs longer than this after the latest begin, even if
    /// a window stays warped.
    static let maxWatch: Double = 1.5
    /// A warped sighting stays current this long without a fresh sample —
    /// covers a couple of dropped frames, not the animation.
    static let freshness: Double = 0.1
    /// How long a warped window that left the on-screen list keeps reading
    /// animating.
    static let vanishHold: Double = 0.5
    /// Listed-vs-own size difference below this is rounding, not a warp.
    static let sizeTolerance: CGFloat = 1

    private struct Anim {
        var until: Double
        /// Seen warped at least once (vs. announced ahead of the warp).
        var warped: Bool
        /// Left the on-screen list after being seen warped.
        var vanished: Bool
    }

    private var watchEnd: Double = 0
    private var capEnd: Double = 0
    private var anims: [CGWindowID: Anim] = [:]

    static func isAnimating(listed: CGRect, own: CGRect) -> Bool {
        abs(listed.size.width - own.size.width) > sizeTolerance
            || abs(listed.size.height - own.size.height) > sizeTolerance
    }

    /// Opens (or extends) the watch. True when a new watch opened, i.e.
    /// the caller should start its frame clock.
    mutating func begin(now: Double) -> Bool {
        let opened = !isWatching(now: now)
        watchEnd = now + Self.watchDuration
        capEnd = now + Self.maxWatch
        return opened
    }

    func isWatching(now: Double) -> Bool {
        if now < watchEnd { return true }
        guard now < capEnd else { return false }
        return anims.values.contains { $0.warped && !$0.vanished && now < $0.until }
    }

    /// stackd is minimizing `windowID` itself: it reads animating from now,
    /// ahead of the warp, for up to `watchDuration` unless a warp takes
    /// over. Opens the watch. True when the caller should announce it.
    mutating func expect(_ windowID: CGWindowID, now: Double) -> Bool {
        _ = begin(now: now)
        if isAnimating(windowID, now: now) { return false }
        anims[windowID] = Anim(until: now + Self.watchDuration, warped: false, vanished: false)
        return true
    }

    /// One frame's comparison. `warped` are the tracked windows whose sizes
    /// differ this frame, `listed` every window on the on-screen list.
    /// Returns the windows whose animation starts this frame, to announce.
    mutating func sample(warped: Set<CGWindowID>, listed: Set<CGWindowID>, now: Double) -> [CGWindowID] {
        var started: [CGWindowID] = []
        for wid in warped.sorted() {
            if !isAnimating(wid, now: now) { started.append(wid) }
            anims[wid] = Anim(until: now + Self.freshness, warped: true, vanished: false)
        }
        for (wid, anim) in anims where !warped.contains(wid) && anim.warped && now < anim.until {
            if listed.contains(wid) {
                anims[wid] = nil
            } else if !anim.vanished {
                anims[wid] = Anim(until: now + Self.vanishHold, warped: true, vanished: true)
            }
        }
        return started
    }

    func isAnimating(_ windowID: CGWindowID, now: Double) -> Bool {
        guard let anim = anims[windowID] else { return false }
        return now < anim.until
    }

    mutating func prune(now: Double) {
        anims = anims.filter { now < $0.value.until }
    }
}

/// Impure shell for `WindowAnimationWatch`: runs the per-frame
/// window-list vs SkyLight comparison on the shared display link while a
/// watch is open, and fires `sd.window.animating { id, frame, visualFrame }`
/// once per window per animation. `frame` is the window's own frame,
/// `visualFrame` the warped bounds on screen. Only AX-tracked windows are
/// compared. Main-thread only.
final class WindowAnimationObserver {
    static let shared = WindowAnimationObserver()
    private init() {}

    // SLSGetWindowBounds(cid, wid, &rect) → CGError. The window's own
    // frame, top-left global coordinates like kCGWindowBounds.
    private typealias GetWindowBoundsFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    private static let getWindowBounds: GetWindowBoundsFn? = SkyLight.sym("SLSGetWindowBounds")

    private var watch = WindowAnimationWatch()
    private var clock: Token?

    func animationBegan() {
        _ = watch.begin(now: CFAbsoluteTimeGetCurrent())
        startClock()
    }

    func isAnimating(windowID: CGWindowID) -> Bool {
        watch.isAnimating(windowID, now: CFAbsoluteTimeGetCurrent())
    }

    /// Announces a minimize stackd itself started, at the call rather than
    /// when the window server's animation shows up. Frame and visual frame
    /// are the same: the warp hasn't begun.
    func noteMinimizing(windowID: CGWindowID) {
        guard let own = Self.ownBounds(windowID) else { return }
        if watch.expect(windowID, now: CFAbsoluteTimeGetCurrent()) {
            announce(windowID, frame: own, visualFrame: own)
        }
        startClock()
    }

    private func startClock() {
        guard clock == nil else { return }
        // subscribe primes the callback, so the first comparison runs now.
        clock = DisplayLinkObserver.shared.subscribe { [weak self] in self?.tick() }
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        guard watch.isWatching(now: now) else {
            clock?.cancel()
            clock = nil
            watch.prune(now: now)
            return
        }
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }
        var listed = Set<CGWindowID>()
        var warped: [CGWindowID: (own: CGRect, listed: CGRect)] = [:]
        for entry in info {
            guard let wid = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            listed.insert(wid)
            guard (entry[kCGWindowLayer as String] as? Int).map(Windows.isAppWindowLevel) == true,
                  WindowsAXObserver.shared.pidFor(wid: wid) != nil,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  let own = Self.ownBounds(wid),
                  WindowAnimationWatch.isAnimating(listed: bounds, own: own)
            else { continue }
            warped[wid] = (own, bounds)
        }
        for wid in watch.sample(warped: Set(warped.keys), listed: listed, now: now) {
            guard let w = warped[wid] else { continue }
            announce(wid, frame: w.own, visualFrame: w.listed)
        }
    }

    private func announce(_ wid: CGWindowID, frame: CGRect, visualFrame: CGRect) {
        func rect(_ r: CGRect) -> [String: Int] {
            ["x": Int(r.origin.x), "y": Int(r.origin.y), "w": Int(r.size.width), "h": Int(r.size.height)]
        }
        WindowDebug.log("animating wid=\(wid) frame=\(frame) visual=\(visualFrame)")
        AppDelegate.shared?.host?.bang(name: "sd.window.animating", detail: [
            "id": Int(wid), "frame": rect(frame), "visualFrame": rect(visualFrame)
        ])
    }

    private static func ownBounds(_ wid: CGWindowID) -> CGRect? {
        guard let fn = getWindowBounds, SkyLight.cid != 0 else { return nil }
        var rect = CGRect.zero
        return fn(SkyLight.cid, UInt32(wid), &rect) == 0 ? rect : nil
    }
}
