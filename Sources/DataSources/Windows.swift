import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// SLSTransaction* — atomic batch of window geometry/order mutations committed
// to WindowServer in one round-trip. Consumed by Overlay.swift's per-tick
// reshape+order. (sd.windows.batch does not use it: the batch path queues
// full frames and applies them all-AX at commit — see the batchSink doc
// comment in WindowsByID for the channel-split race that rules out the
// SLS-position/AX-size split.)
//
// Lives here (not in Sources/Private/SkyLight.swift) because the primary
// domain is windows; Overlay imports as `Windows.Transaction.*`. Mirrors
// Hammerspoon's per-extension SPI ownership.
//
// Signatures verified against yabai/src/misc/extern.h and JankyBorders/
// src/misc/extern.h (SLSTransactionMoveWindowWithGroup: (CFTypeRef, uint32_t,
// CGPoint), point = absolute CGS top-left global origin — same space as
// AX/CG, no flip).
// Permanent diagnostic switch for window lifecycle plumbing.
// STACKD_WIN_DEBUG=1 turns on stderr logs at every gate in the
// source → bang → JS fan-out chain so a "events never arrived" symptom
// can be triaged in one daemon relaunch instead of guessing. Lives here
// (not in AppDelegate) so the CGS callbacks — which fire off the main
// thread before reaching DispatchQueue — can log without an extra hop.
enum WindowDebug {
    static let enabled: Bool = ProcessInfo.processInfo.environment["STACKD_WIN_DEBUG"] != nil
    // Autoclosure: several call sites sit on hot paths (the CGS callback
    // fires for every window event system-wide; AX moved/resized fire
    // throughout drags) and their interpolations — enum reflection
    // included — must not be built when the switch is off.
    static func log(_ s: @autoclosure () -> String) {
        if enabled { Log.write("win-dbg \(s())") }
    }
}

/// Debug-only: logs every main run-loop pass that kept the thread busy past
/// `threshold` — the stretch between waking and going back to sleep. Every
/// window event, bridge call and display-link tick runs on main, so a long
/// pass here delays all of them at once.
enum MainStallWatch {
    static let threshold: Double = 0.04
    private static var observer: CFRunLoopObserver?

    /// The log line for one run-loop pass that stayed busy `busy` seconds,
    /// or nil when it was short enough to stay quiet.
    static func report(busy: Double) -> String? {
        busy > threshold ? "main: busy \(Int((busy * 1000).rounded()))ms" : nil
    }

    static func install() {
        guard WindowDebug.enabled, observer == nil else { return }
        var woke = CFAbsoluteTimeGetCurrent()
        let obs = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true, 0
        ) { _, activity in
            let now = CFAbsoluteTimeGetCurrent()
            if activity == .afterWaiting { woke = now; return }
            if let line = report(busy: now - woke) { WindowDebug.log(line) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        observer = obs
    }
}

enum WindowTransaction {
    typealias CreateFn          = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    typealias CommitFn          = @convention(c) (CFTypeRef, Int32) -> Int32
    typealias OrderWindowFn     = @convention(c) (CFTypeRef, UInt32, Int32, UInt32) -> Int32
    // (tx, wid, origin) — origin in CGS global top-left coordinates, no
    // AppKit flip. "WithGroup" moves attached child windows along; our
    // panels have none, so it's a plain move.
    typealias MoveWithGroupFn   = @convention(c) (CFTypeRef, UInt32, CGPoint) -> Int32

    static let create:         CreateFn?         = SkyLight.sym("SLSTransactionCreate")
    static let commit:         CommitFn?         = SkyLight.sym("SLSTransactionCommit")
    static let orderWindow:    OrderWindowFn?    = SkyLight.sym("SLSTransactionOrderWindow")
    static let moveWithGroup:  MoveWithGroupFn?  = SkyLight.sym("SLSTransactionMoveWindowWithGroup")
}

/// Named window-server properties on windows this connection owns.
/// SLSSetWindowProperty stores a CF value under a string key on the
/// window-server window; SLSCopyWindowProperty reads it back (+1 retained).
enum WindowServerProperty {
    typealias SetFn  = @convention(c) (Int32, UInt32, CFString, CFTypeRef) -> Int32
    typealias CopyFn = @convention(c) (Int32, UInt32, CFString, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>) -> Int32

    static let set:  SetFn?  = SkyLight.sym("SLSSetWindowProperty")
    static let copy: CopyFn? = SkyLight.sym("SLSCopyWindowProperty")

    /// True keeps the window out of the screencapture window picker
    /// (Cmd-Shift-4 then Space, Cmd-Shift-5 window mode). Full-screen and
    /// region captures and screen recording still include it.
    static let ignoreForScreencaptureSelection = "IgnoreForScreencaptureWindowSelection"

    /// False when the SPI is missing, `wid` is 0, or the server refuses.
    @discardableResult
    static func setBool(_ key: String, _ value: Bool, on wid: CGWindowID) -> Bool {
        guard let set = set, wid != 0, SkyLight.cid != 0 else { return false }
        let cf: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        return set(SkyLight.cid, wid, key as CFString, cf) == 0
    }

    /// Nil when the SPI is missing, the property is unset, or it isn't a
    /// boolean.
    static func bool(_ key: String, of wid: CGWindowID) -> Bool? {
        guard let copy = copy, wid != 0, SkyLight.cid != 0 else { return nil }
        var out: Unmanaged<CFTypeRef>?
        guard copy(SkyLight.cid, wid, key as CFString, &out) == 0,
              let value = out?.takeRetainedValue(),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }
}

// Everything window-related, by source-of-truth:
//
//   Windows                  — CGWindowList enumeration (.all), AX-focused
//                              window of the frontmost app (.focused), plus
//                              frame/minimize/fullscreen/raise actions on
//                              that focused window.
//
//   AXShim                   — vendored `_AXUIElementGetWindow` private SPI
//                              that maps an AXUIElement back to its CGWindowID.
//                              Loaded once via dlsym(RTLD_DEFAULT).
//
//   WindowsByID              — per-window actions targeting a specific
//                              CGWindowID via the AXShim lookup; per-pid
//                              ID→AX cache so consecutive calls skip the
//                              app-windows traversal.
//
//   WindowsLifecycleObserver — 10s CGWindowList-diff safety backstop behind
//                              WindowsAXObserver (the primary). Fires
//                              create/destroy/title-change callbacks only
//                              for events AX did not cover (missed-by-ax
//                              drift sensor). Always-on at startup.
//
//   FrontmostWindowObserver  — event-driven AX notification fan-out for the
//                              focused app's focus / title changes. Rebinds
//                              its per-pid AXAppObserver on app activation.

// MARK: - Windows: CGWindowList + focused-window AX

enum Windows {
    /// The AX half of a focused-window read: everything that talks to the
    /// app. Safe off main.
    struct FocusedWindowRead {
        let title: String
        let origin: CGPoint
        let size: CGSize
        let id: CGWindowID?
    }

    /// `pid`'s focused window, read over AX with a 0.1s cap so an
    /// unresponsive app can't hang the caller. Any thread.
    static func readFocusedWindow(pid: pid_t) -> FocusedWindowRead? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.1)

        var focusedRef: AnyObject?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focusedRef)
        guard err == .success, let focused = focusedRef else { return nil }
        // swiftlint:disable:next force_cast
        let win = focused as! AXUIElement

        var titleRef: AnyObject?
        _ = AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)

        var posRef: AnyObject?
        var sizeRef: AnyObject?
        _ = AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
        _ = AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
        var pt = CGPoint.zero
        var sz = CGSize.zero
        if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
        if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &sz) }

        // Recover CGWindowID via the private SPI so per-window-id consumers
        // (sd.windows.byId, tiler-style stacks) can target this exact window.
        var winId: CGWindowID = 0
        var id: CGWindowID? = nil
        if let getWindow = AXShim.getWindow, getWindow(win, &winId) == .success {
            id = winId
        }
        return FocusedWindowRead(title: (titleRef as? String) ?? "", origin: pt, size: sz, id: id)
    }

    /// The sd.windows.focused payload for a read of `app`'s focused window.
    /// Main thread (display lookup walks NSScreen).
    static func focusedPayload(_ read: FocusedWindowRead, app: NSRunningApplication) -> [String: Any] {
        let pt = read.origin
        var out: [String: Any] = [
            "app": app.localizedName ?? "",
            "pid": Int(app.processIdentifier),
            "title": read.title,
            "frame": ["x": Int(pt.x), "y": Int(pt.y), "w": Int(read.size.width), "h": Int(read.size.height)]
        ]
        if let id = read.id { out["id"] = Int(id) }
        // Bundle identifier — stable across launches (pid recycles), so
        // stacks routing by app should key on this.
        if let bid = app.bundleIdentifier { out["bundleId"] = bid }
        // Enrich with the containing display so consumers don't reimplement
        // the forPoint loop. Probe at the window's top-left in CG coords —
        // matches every other xy in sd.*. Display.forPoint is cheap
        // (NSScreen.screens iteration, no DDC). null when off-screen.
        if let d = Display.forPoint(pt) { out["display"] = d }
        // CGSpaceID of the space the window appears on — first entry, since
        // 99% of windows live on exactly one space (the user-arranged case).
        // Multi-space windows (sticky-on-all-spaces / fullscreen-with-aux)
        // still get a sensible space here; consumers that need the full set
        // call sd.spaces.forWindow(id).
        if let id = read.id, let first = Spaces.windowSpaces(windowID: UInt32(id)).first {
            out["space"] = Int(first)
        }
        return out
    }

    // Focused window for the frontmost app, via Accessibility. Main thread.
    static func focused() -> [String: Any]? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let read = readFocusedWindow(pid: app.processIdentifier) else { return nil }
        return focusedPayload(read, app: app)
    }

    // Actions below all operate on the AX focused window of the frontmost app.
    // Per-window-id actions (move an arbitrary background window) live in
    // WindowsByID and use the _AXUIElementGetWindow shim.

    private static func focusedWindowEl() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.1)
        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &ref)
        guard err == .success, let win = ref else { return nil }
        return (win as! AXUIElement)
    }

    @discardableResult
    static func setFocusedFrame(x: Double, y: Double, w: Double, h: Double) -> Bool {
        guard let win = focusedWindowEl() else { return false }
        var pos  = CGPoint(x: x, y: y)
        var size = CGSize(width: w, height: h)
        guard let posVal  = AXValueCreate(.cgPoint, &pos),
              let sizeVal = AXValueCreate(.cgSize,  &size) else { return false }
        // Size → position → size; see WindowsByID.setFrame for the why.
        _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute     as CFString, sizeVal)
        let posOK  = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
        let sizeOK = AXUIElementSetAttributeValue(win, kAXSizeAttribute     as CFString, sizeVal)
        return posOK == .success && sizeOK == .success
    }

    @discardableResult
    static func minimizeFocused(_ value: Bool) -> Bool {
        guard let win = focusedWindowEl() else { return false }
        return AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, value as CFTypeRef) == .success
    }

    @discardableResult
    static func fullscreenFocused(_ value: Bool) -> Bool {
        guard let win = focusedWindowEl() else { return false }
        return AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, value as CFTypeRef) == .success
    }

    @discardableResult
    static func raiseFocused() -> Bool {
        guard let win = focusedWindowEl() else { return false }
        return AXUIElementPerformAction(win, kAXRaiseAction as CFString) == .success
    }

    // All normal windows known to WindowServer, including minimized / other-space
    // / offscreen. Prefers SLSCopyWindowsWithOptionsAndTags (yabai's route) for
    // authority + completeness; falls back to CGWindowListCopyWindowInfo(.optionAll)
    // if the SPI symbol fails to resolve. Each entry carries `onscreen: Bool` so
    // consumers that want only visible windows can filter without losing the
    // option to see the full inventory.
    /// Own-pid cache — stackd's own panels show up in CGWindowList alongside
    /// real user windows and pollute every consumer that iterates them
    /// (windowscape tiling, framemaster border-drawing, custom switchers,
    /// etc.). Exclude them by default; stacks that genuinely need to enumerate
    /// stackd's own panels can opt in.
    private static let ownPid: Int = Int(ProcessInfo.processInfo.processIdentifier)

    static func all(includeOwn: Bool = false, includeNonStandard: Bool = false) -> [[String: Any]] {
        // SLSCopyWindowsWithOptionsAndTags is the yabai-style "authoritative"
        // path but crashes inside SkyLight on macOS 26 (Tahoe) — repro: any
        // stack with `windows` permission segfaults at startWorkspace's
        // first push. Until the SPI signature is re-verified on Tahoe we
        // route through the public CGWindowListCopyWindowInfo only.
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) else { return [] }
        guard WindowDebug.enabled else {
            return decode(raw as! [[String: Any]], includeOwn: includeOwn, includeNonStandard: includeNonStandard)
        }
        let began = CFAbsoluteTimeGetCurrent()
        _ = WindowAddressabilityCache.takeLiveProbeCount()
        let out = decode(raw as! [[String: Any]], includeOwn: includeOwn, includeNonStandard: includeNonStandard)
        let ms = Int((CFAbsoluteTimeGetCurrent() - began) * 1000)
        if ms >= 10 {
            WindowDebug.log("windows.all: \(ms)ms, \(WindowAddressabilityCache.takeLiveProbeCount()) live AX probes")
        }
        return out
    }

    private static func decode(_ list: [[String: Any]], includeOwn: Bool, includeNonStandard: Bool = false) -> [[String: Any]] {
        list.compactMap { info -> [String: Any]? in
            guard let num   = info[kCGWindowNumber as String]    as? Int,
                  let layer = info[kCGWindowLayer  as String]    as? Int,
                  layer == 0,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  let pid   = info[kCGWindowOwnerPID  as String] as? Int,
                  let bounds = info[kCGWindowBounds as String]   as? [String: CGFloat]
            else { return nil }
            if !includeOwn && pid == ownPid { return nil }
            let onscreen = (info[kCGWindowIsOnscreen as String] as? Int) ?? 0
            // Enrich with AX-derived fields the stack would otherwise have
            // to probe per-pass:
            //   addressable: AX can resolve an AXUIElement for this id
            //   isStandard:  AXSubrole == AXStandardWindow (filters out
            //                Inspector / preferences / helper windows)
            // Both cached per (pid, id) with a TTL so a 50-window
            // CGWindowList push doesn't fan out 50+50 AX RPCs every time.
            let probe = WindowAddressabilityCache.probe(pid: pid_t(pid), windowID: CGWindowID(num))
            // Skip non-standard windows (Notification Center banners,
            // Spotlight overlays, popovers, sheets, system HUDs) by
            // default. Matches Hammerspoon's `hs.window.allWindows()` and
            // yabai's `window_manager_find_windows_on_storage`. Stacks
            // that genuinely need the full set pass `includeNonStandard:
            // true`.
            if !includeNonStandard && !probe.isStandard { return nil }
            let originX = Int(bounds["X"] ?? 0)
            let originY = Int(bounds["Y"] ?? 0)
            // Mirror Windows.focused()'s display enrichment for every entry
            // in the list. Stacks iterating sd.windows.all (windowscape tiler,
            // window switchers, focus-per-display HUDs) get the containing
            // screen without a per-id RPC roundtrip. Space deliberately
            // omitted here — Spaces.windowSpaces is a per-window CGS call,
            // and a 50-window list shouldn't pay 50 of them per push.
            // sd.spaces.forWindow(id) stays the path for that.
            var out: [String: Any] = [
                "id": num,
                "app": owner,
                "pid": pid,
                "title": info[kCGWindowName as String] as? String ?? "",
                "onscreen": onscreen != 0,
                "addressable": probe.addressable,
                "isStandard":  probe.isStandard,
                "isMinimized": probe.isMinimized,
                "frame": [
                    "x": originX,
                    "y": originY,
                    "w": Int(bounds["Width"] ?? 0),
                    "h": Int(bounds["Height"] ?? 0)
                ]
            ]
            if let d = Display.forPoint(CGPoint(x: originX, y: originY)) {
                out["display"] = d
            }
            return out
        }
    }
}

// MARK: - WindowAddressabilityCache
//
// AX probe results for each (pid, CGWindowID) cached with a TTL. Used to
// enrich Windows.all() without paying an AX round-trip per window per push.
// First call for an id pays the elementFor + subrole lookup; subsequent
// reads within the TTL hit the cache. Cache is invalidated when the pid
// goes away (WindowsByID.invalidateCache(pid:) is called from
// WindowsLifecycleObserver on window-destroyed events).
//
// Why on the daemon side: lets every stack consume sd.windows.all without
// each one re-implementing per-pass probing — otherwise a tiler does
// 2N AX calls per tile pass, costly and racy.
enum WindowAddressabilityCache {
    struct Probe {
        let addressable: Bool
        let isStandard: Bool
        let isMinimized: Bool
        let ts: TimeInterval
        /// Consecutive failed probes of an unaddressable window; scales its
        /// re-probe gate (failTtl(after:)).
        var failures: Int = 0
    }
    private static var cache: [String: Probe] = [:]
    /// Live (uncached) probes since the last `takeLiveProbeCount()`, for the
    /// debug timing line in Windows.all().
    private static var liveProbes = 0
    // First-seen wall-time per (pid, windowID). A window gets a grace
    // window of OPTIMISTIC_GRACE_MS during which probe misses report
    // addressable=true (instead of false). Avoids the boot-burst race
    // where AX is slammed and Terminal's first 5+ probes time out in
    // milliseconds. Once the grace expires, real misses mark false.
    private static var firstSeenAt: [String: TimeInterval] = [:]
    private static let optimisticGraceMs: TimeInterval = 5.0
    private static let lock = NSLock()
    // Positive probes (addressable AND standard) are cached PERMANENTLY
    // (until pid death — see the NSWorkspace.didTerminateApplication
    // observer in install()). Reasoning: AX's 100ms messaging timeout drops
    // queries under load (spotlight indexing, brightness poll, rapid tile
    // passes); a once-addressable standard window doesn't randomly stop
    // being one while its pid is alive. Re-probing on TTL expiry would let
    // a transient AX timeout drop a once-established verdict.
    // Negative isStandard verdicts are NOT permanent: a probe racing a
    // minimize/deminimize/space-restore transition can read a bogus subrole
    // (Terminal reports AXDialog mid-transition while AXMinimized already
    // reads false), and a permanent false verdict silently drops a real
    // window out of Windows.all() with no heal path — no poll, rescan, or
    // event ever re-probes it. nonStandardTtl bounds the damage: a genuine
    // dialog/sheet just re-confirms once per TTL (≤1 AX read per layer-0
    // non-standard window), a poisoned real window heals on the first
    // re-probe after the transition settles — worst case nonStandardTtl
    // plus one 10s poll tick on an otherwise idle system.
    // Failed probes are re-checked quickly at first so an app that JUST
    // opened a window gets re-evaluated within a beat, then less and less
    // often: a window that keeps failing is one AX does not vend (helper
    // chrome, offscreen surfaces), and Windows.all() runs on main for every
    // create/destroy/focus push — re-probing ~100 of them at a flat 0.5s
    // cost 30–100ms of main per window event. Windows that do become
    // addressable later are found without the timer: the AX create observer
    // and CGS 1325 re-finds confirm() them, and a space change calls
    // retryFailures().
    static let failTtl: TimeInterval = 0.5
    static let failTtlCap: TimeInterval = 30.0
    static let nonStandardTtl: TimeInterval = 3.0

    /// Re-probe gate for an unaddressable verdict after `failures`
    /// consecutive failures: failTtl, doubling per failure, capped.
    /// Once capped, the gate is stretched by a per-window factor in [1, 2)
    /// so windows that failed equally often don't all come due in the same
    /// Windows.all() call.
    static func failTtl(after failures: Int, windowID: CGWindowID = 0) -> TimeInterval {
        let doublings = min(max(0, failures - 1), 16)
        let gate = failTtl * Double(1 << doublings)
        guard gate >= failTtlCap else { return gate }
        return failTtlCap * (1 + Double(windowID % 16) / 16)
    }

    /// Whether a cached probe may be returned as-is or must be re-read
    /// live. Pure so the expiry rules above are unit-testable.
    static func cacheVerdictUsable(_ p: Probe, now: TimeInterval, windowID: CGWindowID = 0) -> Bool {
        if p.addressable {
            return p.isStandard || (now - p.ts) < nonStandardTtl
        }
        return (now - p.ts) < failTtl(after: p.failures, windowID: windowID)
    }

    static func probe(pid: pid_t, windowID: CGWindowID,
                      now: TimeInterval = Date().timeIntervalSince1970) -> Probe {
        let key = "\(pid)|\(windowID)"
        lock.lock()
        if let p = cache[key], cacheVerdictUsable(p, now: now, windowID: windowID) {
            lock.unlock()
            return p
        }
        liveProbes += 1
        lock.unlock()
        // Probe outside the lock — AX calls hop to main thread internally.
        var el: AXUIElement?
        var isStd = false
        var isMin = false
        var subroleErr: AXError = .success
        for attempt in 0..<2 {
            el = WindowsByID.elementFor(windowID: windowID, pid: pid)
            isStd = false
            isMin = false
            guard let e = el else { break }
            var minRef: AnyObject?
            if AXUIElementCopyAttributeValue(e, kAXMinimizedAttribute as CFString, &minRef) == .success,
               let b = minRef as? Bool {
                isMin = b
            }
            var subroleRef: AnyObject?
            subroleErr = AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &subroleRef)
            isStd = standardVerdict(subrole: subroleRef as? String, isMinimized: isMin)
            guard StaleElementRetry.shouldReResolve(readError: subroleErr, attempt: attempt) else { break }
            // The cached element may be dead while the window lives on
            // (sleep/wake): drop it so elementFor re-walks kAXWindows.
            WindowsByID.invalidateCache(pid: pid, windowID: windowID)
        }
        let addressable = (el != nil)
        lock.lock()
        let existing = cache[key]
        let probe: Probe
        let shouldCache: Bool
        if addressable {
            // Success — cache true permanently.
            probe = Probe(addressable: true, isStandard: isStd, isMinimized: isMin, ts: now)
            shouldCache = true
        } else if let e = existing, e.addressable {
            // Sticky-success: established-true never flips to false on a
            // transient miss. Keep the whole cached verdict — this branch
            // means the probe FAILED (el is nil), so isMin carries no real
            // reading; live minimize flips arrive via setMinimized().
            // ts=now also paces an expired negative-isStandard entry: each
            // failed re-probe buys one more nonStandardTtl of patience
            // instead of hammering AX on every Windows.all() pass.
            probe = Probe(addressable: true, isStandard: e.isStandard, isMinimized: e.isMinimized, ts: now)
            shouldCache = true
        } else {
            // No success yet. Time-based optimism: report addressable: true
            // for the first optimisticGraceMs after we first saw the id. AX
            // is slammed at boot — 5+ misses can happen in milliseconds,
            // count-based thresholds get blown through. Time-based gives
            // the app a fair shot at responding before we mark it dead.
            //
            // isStandard stays FALSE during grace — we can't risk tiling
            // a sheet / dialog / save-panel that happens to be born when
            // AX is busy. The tiler's first-entry filter checks isStandard,
            // so unknown-subrole windows stay out of rotation until a real
            // AX probe confirms AXStandardWindow. Worst-case UX: a new
            // standard window pops in non-tiled for a frame or two before
            // the next probe lands and the next push includes it.
            let firstSeen = firstSeenAt[key] ?? now
            if firstSeenAt[key] == nil { firstSeenAt[key] = now }
            let inGrace = (now - firstSeen) < optimisticGraceMs
            if inGrace {
                // CRUCIAL: do NOT cache the grace-optimism result. The
                // sticky-success branch above ("if p.addressable") would
                // then lock in `addressable: true, isStandard: false` for
                // the window's entire lifetime — meaning every window the
                // daemon sees during an AX-stress burst (boot, full rebuild
                // restart, spotlight indexing burst, etc.) would never
                // re-enter tile rotation. By NOT caching, the next call
                // re-probes; if AX has caught up we hit the success branch
                // and cache the real verdict.
                probe = Probe(addressable: true, isStandard: false, isMinimized: false, ts: now)
                shouldCache = false
            } else {
                probe = Probe(addressable: false, isStandard: false, isMinimized: false, ts: now,
                              failures: (existing?.failures ?? 0) + 1)
                shouldCache = true
            }
        }
        if shouldCache { cache[key] = probe }
        lock.unlock()
        // Verdict flips are rare and are what silently drops a window from
        // every tiler — say why.
        if shouldCache, let old = existing,
           old.addressable != probe.addressable || old.isStandard != probe.isStandard {
            log("windows: wid=\(windowID) pid=\(pid) addressable \(old.addressable)→\(probe.addressable) standard \(old.isStandard)→\(probe.isStandard) (element \(el == nil ? "unresolved" : "ok"), subrole read \(subroleErr.rawValue))")
        } else if shouldCache, existing == nil, !probe.addressable {
            // Common for layer-0 windows AX doesn't vend (helpers, offscreen
            // chrome) — debug-only; the flips above are the signal.
            WindowDebug.log("windows: wid=\(windowID) pid=\(pid) unaddressable after grace (element unresolved)")
        }
        return probe
    }

    /// Let every unaddressable verdict be re-probed on its next read, keeping
    /// its failure count: one fresh look (after a space change, when AX may
    /// now vend a window it did not), then the same backoff if it still fails.
    static func retryFailures() {
        lock.lock(); defer { lock.unlock() }
        for (key, p) in cache where !p.addressable {
            cache[key] = Probe(addressable: false, isStandard: false, isMinimized: false,
                               ts: -.infinity, failures: p.failures)
        }
    }

    /// Live probes since the previous call.
    static func takeLiveProbeCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = liveProbes
        liveProbes = 0
        return n
    }

    /// Forget every verdict except established positives, so windows get
    /// re-probed with fresh elements (after wake).
    static func dropNonPositive() {
        lock.lock(); defer { lock.unlock() }
        cache = cache.filter { $0.value.addressable && $0.value.isStandard }
        firstSeenAt.removeAll()
    }

    static func invalidate(pid: pid_t) {
        let prefix = "\(pid)|"
        lock.lock(); defer { lock.unlock() }
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        firstSeenAt = firstSeenAt.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Single-window invalidation for the AX window-destroyed path. Document
    /// apps (Preview) keep closed windows alive in the WindowServer, so the
    /// id stays in CGWindowList while AX drops it — a sticky isStandard:true
    /// entry then feeds the ghost into sd.windows.all all session, so a
    /// consumer counts closed windows and never sees the app as windowless.
    /// One key only: the pid's OTHER windows keep their sticky verdicts
    /// (the reason destroy events must not use the pid-wide overload above).
    /// A falsely-reported destroy self-heals — the next probe re-establishes
    /// sticky success.
    static func invalidate(pid: pid_t, windowID: CGWindowID) {
        let key = "\(pid)|\(windowID)"
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: key)
        firstSeenAt.removeValue(forKey: key)
    }

    /// AX-confirmed verdict, bypassing the probe machinery. WindowsAXObserver
    /// already holds the window element at create time and read its subrole —
    /// re-deriving the same answer through `probe()` is not just wasteful but
    /// actively harmful: under AX load the probe lands in the optimism grace,
    /// which reports `isStandard: false`, which makes `Windows.all()` filter
    /// the just-created window OUT of the very snapshot AppDelegate pumps in
    /// response to the create. Seeds the same sticky-success entry a
    /// successful probe would, so the next `Windows.all()` pass includes the
    /// window as soon as CGWindowList lists it.
    static func confirm(pid: pid_t, windowID: CGWindowID, isStandard: Bool, isMinimized: Bool,
                        now: TimeInterval = Date().timeIntervalSince1970) {
        let key = "\(pid)|\(windowID)"
        lock.lock(); defer { lock.unlock() }
        cache[key] = Probe(addressable: true, isStandard: isStandard, isMinimized: isMinimized, ts: now)
    }

    /// Live isMinimized update from AX miniaturize/deminiaturize events.
    /// The sticky-success fast path in `probe()` returns the cached entry
    /// without re-reading AX, so without this hook the isMinimized bit
    /// freezes at whatever the first successful probe saw. No-op when the
    /// (pid, wid) has no established-success entry — the next real probe
    /// reads the live value anyway.
    /// The entry's ts is preserved: ts schedules a negative isStandard
    /// verdict's re-probe, and minimize events arrive exactly during the
    /// transitions that produce bogus negative verdicts — re-stamping here
    /// would let minimize churn push the heal deadline out indefinitely.
    static func setMinimized(pid: pid_t, windowID: CGWindowID, _ value: Bool) {
        let key = "\(pid)|\(windowID)"
        lock.lock(); defer { lock.unlock() }
        guard let p = cache[key], p.addressable else { return }
        cache[key] = Probe(addressable: true, isStandard: p.isStandard, isMinimized: value, ts: p.ts)
    }

    /// Subrole reading → isStandard verdict, minimize-aware. A minimized
    /// window's AXSubrole is unreliable — Terminal's minimized windows
    /// report AXDialog (macOS 26) — so a window whose first successful
    /// probe happened while it sat in the Dock would get sticky-cached as
    /// non-standard and filtered out of Windows.all(), leaving consumers to
    /// read the app as windowless. Only real user windows can be minimized
    /// to the Dock, so minimized ⇒ standard regardless of the reading.
    static func standardVerdict(subrole: String?, isMinimized: Bool) -> Bool {
        isMinimized || subrole == (kAXStandardWindowSubrole as String)
    }
}

// MARK: - AXShim: _AXUIElementGetWindow private SPI

enum AXShim {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static let getWindow: GetWindowFn? = {
        // _AXUIElementGetWindow is exported by ApplicationServices itself;
        // dlsym(RTLD_DEFAULT, ...) finds it without needing a framework path.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            log("_AXUIElementGetWindow unavailable")
            return nil
        }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()
}

// MARK: - WindowsByID: per-window actions targeting a CGWindowID

/// When a failed attribute read on a cached element means "re-resolve the
/// element and read again" rather than a real answer about the window.
enum StaleElementRetry {
    static func shouldReResolve(readError: AXError, attempt: Int) -> Bool {
        attempt == 0 && (readError == .invalidUIElement || readError == .cannotComplete)
    }
}

/// Whether a window's per-window AX observers need (re)attaching, given
/// what's stored and what AX resolves for it now. Generic so it's testable
/// without live AXUIElements.
enum PerWindowInstallDecision: Equatable {
    case install, replace, keep

    static func decide<T>(existing: T?, fresh: T?, same: (T, T) -> Bool) -> PerWindowInstallDecision {
        guard let fresh = fresh else { return .keep }
        guard let existing = existing else { return .install }
        return same(existing, fresh) ? .keep : .replace
    }
}

/// Per-app rate limit for the create-triggered AX install retry.
struct AXInstallRetryGate {
    static let minInterval: Double = 2.0
    private var lastAttempt: [pid_t: Double] = [:]

    mutating func shouldAttempt(pid: pid_t, now: Double) -> Bool {
        if let last = lastAttempt[pid], now - last < Self.minInterval { return false }
        lastAttempt[pid] = now
        return true
    }
}

/// Pure resolution order for a window's owning pid. `cached` maps each pid
/// to the window ids its AX cache holds; `query` is the single-window
/// CGWindowList fallback.
enum WindowOwnerLookup {
    static func pid(for windowID: CGWindowID,
                    cached: [pid_t: Set<CGWindowID>],
                    query: (CGWindowID) -> pid_t?) -> pid_t? {
        if let hit = cached.first(where: { $0.value.contains(windowID) }) { return hit.key }
        return query(windowID)
    }
}

/// Which focus path WindowsByID.focus takes, and when its AX raise runs.
enum WindowFocusRoute: Equatable {
    /// NSRunningApplication activation + synchronous AX on main.
    case activateApp
    /// SkyLight fronting + key-window event; AXRaise on the app's AX queue
    /// after `raiseAfter` seconds.
    case skyLight(raiseAfter: TimeInterval)

    /// Time for another app's activation to land before raising, so the
    /// raise doesn't contend with the app's own activation handling.
    static let crossAppRaiseDelay: TimeInterval = 0.1

    static func decide(skyLightAvailable: Bool, targetPid: pid_t, frontmostPid: pid_t?) -> WindowFocusRoute {
        guard skyLightAvailable else { return .activateApp }
        return .skyLight(raiseAfter: targetPid == frontmostPid ? 0 : crossAppRaiseDelay)
    }
}

/// The synthetic event records that make a window key in its app: a
/// left-button press then release addressed to the window, with the
/// key-window flag set and the location far outside any content. Both are
/// required: a press with no release leaves some apps (Ghostty) holding a
/// button down and stalling their event loop.
///
/// Layout (0xf8 bytes, all other bytes zero):
///   0x04       declared record length (0xf8)
///   0x08       event type: 0x01 press, 0x02 release
///   0x20..0x2f location, filled with 0xff
///   0x3a       0x10, the make-key-window flag
///   0x3c..0x3f target window id, little-endian
enum KeyWindowEventRecord {
    static let length = 0xF8

    static func pressAndRelease(windowID: CGWindowID) -> [[UInt8]] {
        [record(windowID: windowID, type: 0x01), record(windowID: windowID, type: 0x02)]
    }

    private static func record(windowID: CGWindowID, type: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: length)
        b[0x04] = UInt8(length)
        b[0x08] = type
        for i in 0x20..<0x30 { b[i] = 0xFF }
        b[0x3A] = 0x10
        for i in 0..<4 { b[0x3C + i] = UInt8(truncatingIfNeeded: windowID >> (8 * UInt32(i))) }
        return b
    }
}

/// SkyLight process-fronting SPI for WindowsByID.focus.
enum SkyLightFocus {
    // _SLPSSetFrontProcessWithOptions(psn, wid, mode)
    typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    // SLPSPostEventRecordTo(psn, bytes)
    typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    // GetProcessForPID(pid, psn), deprecated HIServices; resolved at runtime.
    typealias ProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32

    static let setFront: SetFrontFn? = SkyLight.sym("_SLPSSetFrontProcessWithOptions")
    static let postEventRecord: PostEventRecordFn? = SkyLight.sym("SLPSPostEventRecordTo")
    static let processForPID: ProcessForPIDFn? = {
        guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") else { return nil }
        return unsafeBitCast(s, to: ProcessForPIDFn.self)
    }()

    /// The mode flag marking the fronting as user-initiated.
    static let userGenerated: UInt32 = 0x200

    static var available: Bool {
        setFront != nil && postEventRecord != nil && processForPID != nil
    }

    /// Front `pid` with `windowID` and make that window key. False when the
    /// process can't be addressed or the window server refuses; the caller
    /// falls back to app activation.
    static func front(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let setFront = setFront, let post = postEventRecord, let psnFor = processForPID else {
            return false
        }
        var psn = ProcessSerialNumber()
        guard psnFor(pid, &psn) == 0, setFront(&psn, windowID, userGenerated) == 0 else { return false }
        for var record in KeyWindowEventRecord.pressAndRelease(windowID: windowID) {
            let status = record.withUnsafeMutableBufferPointer { post(&psn, $0.baseAddress!) }
            if status != 0 {
                WindowDebug.log("focus: key-window event record for wid=\(windowID) refused (\(status))")
            }
        }
        return true
    }
}

enum WindowsByID {
    // Batch sink. When sd.windows.batch is active, setFrame on a specific id
    // queues the FULL frame here instead of writing AX; commit applies every
    // queued frame through the normal setFrame dance in one main-thread
    // burst. Process-wide because one batch runs at a time (begin refuses to
    // nest, matching the JS-side single-await model).
    //
    // Why all-AX (no SLSTransaction): splitting one window's geometry across
    // two unsynchronized channels — size via AX at setFrame time, position
    // via SLS at commit — races each app's frame cache. AX writes propagate
    // asynchronously to the target app, and an app processing a size set
    // performs a full -[NSWindow setFrame:] (origin + size) with the origin
    // read from its own frame cache — which a server-side SLS move does NOT
    // update. The app's late resize re-asserts its STALE origin over the
    // committed SLS position, stacking windows at old origins / offscreen.
    // Queueing full frames and applying them all on the single AX channel
    // can't hit that race, and it drops the SkyLight symbol dependency that
    // made begin fail outright on some daemon states.
    // WindowTransaction (the SLS enum above) stays: Overlay.swift's per-tick
    // reshape+order still consumes it.
    static var batchSink: ((CGWindowID, CGRect) -> Void)?

    // Pending frames for the open batch. Last-write-wins per window id,
    // first-seen order preserved. Pure struct so the bookkeeping is testable
    // without any window server.
    struct BatchFrameLedger {
        private var entries: [(id: CGWindowID, frame: CGRect)] = []
        mutating func record(id: CGWindowID, frame: CGRect) {
            if let i = entries.firstIndex(where: { $0.id == id }) {
                entries[i].frame = frame
            } else {
                entries.append((id: id, frame: frame))
            }
        }
        mutating func drain() -> [(id: CGWindowID, frame: CGRect)] {
            let out = entries
            entries = []
            return out
        }
    }
    private static var pendingFrames = BatchFrameLedger()

    // Opens a batch and installs the queueing sink. Returns false only when
    // a batch is already open. Main-thread, like every batch entry point.
    @discardableResult
    static func beginBatch() -> Bool {
        if batchSink != nil { return false }
        pendingFrames = BatchFrameLedger()
        batchSink = { id, frame in pendingFrames.record(id: id, frame: frame) }
        return true
    }

    // Applies every queued frame in one burst and closes the batch. The
    // sink is cleared BEFORE applying so the setFrame calls take the direct
    // AX path (and record into the FrameLedger like any other write).
    // `applyFrame` is injectable for tests (default: real setFrame dance).
    @discardableResult
    static func commitBatch(
        applyFrame: (CGWindowID, CGRect) -> Void = applyBatchFrame
    ) -> Bool {
        guard batchSink != nil else { return false }
        batchSink = nil
        for entry in pendingFrames.drain() { applyFrame(entry.id, entry.frame) }
        return true
    }

    // Default frame applier for commitBatch — the same size→pos→size write
    // the non-batch path issues; no-ops when the window vanished mid-batch.
    static func applyBatchFrame(_ windowID: CGWindowID, _ frame: CGRect) {
        _ = setFrame(
            windowID: windowID,
            x: frame.origin.x, y: frame.origin.y,
            w: frame.size.width, h: frame.size.height
        )
    }

    // pid → (CGWindowID → AXUIElement). Repopulated lazily on lookup miss.
    private static var axCache: [pid_t: [CGWindowID: AXUIElement]] = [:]
    private static let cacheLock = NSLock()

    // Invalidate all cached AX handles for a pid. Called from the lifecycle
    // observer when a window of that pid is destroyed (we don't know which one
    // without doing the lookup, so drop the whole pid's cache).
    static func invalidateCache(pid: pid_t) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        // Deliberately a SHALLOW invalidate — only drop the per-pid AX
        // window map IF we'll definitely rebuild it (rare). Actually
        // skip entirely: a destroyed window's stale AXUIElement is
        // harmless (actions on it return -25204 which we already
        // tolerate); rebuilding the WHOLE map on every helper-window
        // destroy is what was causing Terminal's main window's id
        // mapping (between CGWindowID and AXUIElement) to oscillate.
        // The cache self-heals via the next elementFor() call on a
        // not-in-map id (rebuilds the map on miss).
        _ = pid // intentionally unused — see comment above
    }

    static func invalidateCache(pid: pid_t, windowID: CGWindowID) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        axCache[pid]?[windowID] = nil
    }

    static func invalidateAll() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        axCache.removeAll()
    }

    /// Resolves a CGWindowID → AXUIElement by walking the app's window list.
    /// Uses a per-pid cache to amortize the AX traversal across calls.
    static func elementFor(windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        guard let getWindow = AXShim.getWindow else { return nil }

        cacheLock.lock()
        if let cached = axCache[pid]?[windowID] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.1)
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return nil }

        var map: [CGWindowID: AXUIElement] = [:]
        for el in arr {
            var wid: CGWindowID = 0
            if getWindow(el, &wid) == .success {
                map[wid] = el
            }
        }

        cacheLock.lock()
        // MERGE, don't replace. AXWindowsAttribute can return different
        // subsets across calls (apps re-render their window list, helper
        // windows come and go). If we replace, a window present in pass A
        // but absent in pass B disappears from our cache → next probe for
        // that id fails → window dropped from tile rotation. Merging
        // preserves the union of what we've ever seen for this pid.
        // Stale AXUIElements raise -25204 when actioned, which we already
        // tolerate (the per-window invalidate path drops them on destroy).
        var existing = axCache[pid] ?? [:]
        for (wid, el) in map {
            existing[wid] = el  // freshest AX element wins for shared ids
        }
        axCache[pid] = existing
        cacheLock.unlock()
        return existing[windowID]
    }

    // Look up by CGWindowID alone — recover the pid, then dispatch via
    // elementFor(windowID:pid:).
    static func elementFor(windowID: CGWindowID) -> AXUIElement? {
        guard let pid = ownerPID(windowID: windowID) else { return nil }
        return elementFor(windowID: windowID, pid: pid)
    }

    /// Owning pid for a window: the AX element cache already knows it for
    /// every window we've touched, so only an unseen window costs a
    /// single-window CGWindowList query.
    static func ownerPID(windowID: CGWindowID) -> pid_t? {
        cacheLock.lock()
        let cached = axCache.mapValues { Set($0.keys) }
        cacheLock.unlock()
        return WindowOwnerLookup.pid(for: windowID, cached: cached) { wid in
            (windowInfo(windowID: wid)?[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) }
        }
    }

    @discardableResult
    static func setFrame(windowID: CGWindowID, x: Double, y: Double, w: Double, h: Double) -> Bool {
        // Batch mode: queue the full frame; nothing touches AX until commit
        // applies every queued frame in one burst (single channel — see the
        // batchSink doc comment for the channel-split race that rules out a
        // mixed SLS-position/AX-size split). True = queued.
        if let sink = batchSink {
            sink(windowID, CGRect(x: x, y: y, width: w, height: h))
            return true
        }
        guard let el = elementFor(windowID: windowID) else { return false }
        return setFrame(element: el, windowID: windowID, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    /// The write itself, on an already-resolved element (the motion engine's
    /// settle frame reuses the element it animated through). Bypasses the
    /// batch sink — callers check it first.
    static func setFrame(element el: AXUIElement, windowID: CGWindowID, frame: CGRect) -> Bool {
        let ok = writeFrameAX(element: el, frame: frame)
        if ok { FrameLedger.shared.recordWrite(windowID: windowID, frame: frame) }
        return ok
    }

    /// The size→position→size write alone, with no main-thread bookkeeping,
    /// so an app's AX writer queue can run it.
    static func writeFrameAX(element el: AXUIElement, frame: CGRect) -> Bool {
        let x = frame.origin.x, y = frame.origin.y, w = frame.size.width, h = frame.size.height
        var pos = CGPoint(x: x, y: y)
        var sz  = CGSize(width: w, height: h)
        guard let posVal = AXValueCreate(.cgPoint, &pos),
              let szVal  = AXValueCreate(.cgSize,  &sz) else { return false }
        // Size → position → size. Position-first lands the window relative
        // to the OLD size, which on horizontal tiles means apps that
        // discrete-round their dimensions (Terminal: 11.36 px/col, Xcode,
        // Finder list view) end up positioned for the wrong width and the
        // size set afterwards anchors to whatever AX picked. Doing size
        // first lets AX honor the new dimensions; the second size set is
        // the standard hs.window:setFrame belt-and-suspenders for apps
        // that clamped the first size against the still-old position.
        _ = AXUIElementSetAttributeValue(el, kAXSizeAttribute     as CFString, szVal)
        let pOK = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posVal)
        let sOK = AXUIElementSetAttributeValue(el, kAXSizeAttribute     as CFString, szVal)
        return pOK == .success && sOK == .success
    }

    /// One animation step: size and/or position, each only when asked for,
    /// under a bounded messaging timeout so a hung app costs its own writer
    /// queue at most `timeout` per step. True when a write timed out.
    /// Thread-agnostic; the element's timeout is restored to the default.
    static func writeAxesAX(element el: AXUIElement, frame: CGRect,
                            size writeSize: Bool, position writePosition: Bool,
                            order: FrameWriteOrder, timeout: Float) -> Bool {
        AXUIElementSetMessagingTimeout(el, timeout)
        defer { AXUIElementSetMessagingTimeout(el, 0) }
        var timedOut = false
        func setSize() {
            guard writeSize, !timedOut else { return }
            var size = frame.size
            if let sizeVal = AXValueCreate(.cgSize, &size) {
                timedOut = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sizeVal) == .cannotComplete
            }
        }
        func setPosition() {
            guard writePosition, !timedOut else { return }
            var pos = frame.origin
            if let posVal = AXValueCreate(.cgPoint, &pos) {
                timedOut = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posVal) == .cannotComplete
            }
        }
        switch order {
        case .positionThenSize: setPosition(); setSize()
        case .sizeThenPosition: setSize(); setPosition()
        }
        return timedOut
    }

    /// The motion engine's settle frame: two setters in `order`, then a
    /// size read-back, and a third size set only when the app reports a
    /// size other than the one written.
    ///
    /// Diverges from hs.window:setFrame (and `writeFrameAX`), which always
    /// sets size, position, size. The blind third set exists because a size
    /// set can be clamped against the old position; ordering by grow vs.
    /// shrink (see FrameWriteOrder) already avoids that clamp in the common
    /// case, and the read-back catches the rest. Skipping the third set
    /// saves one AX round trip and one extra app layout pass per settle.
    /// Thread-agnostic.
    static func settleFrameAX(element el: AXUIElement, frame: CGRect, order: FrameWriteOrder) -> Bool {
        var pos = frame.origin
        var sz = frame.size
        guard let posVal = AXValueCreate(.cgPoint, &pos),
              let szVal = AXValueCreate(.cgSize, &sz) else { return false }
        var pOK: AXError
        var sOK: AXError
        switch order {
        case .positionThenSize:
            pOK = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posVal)
            sOK = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, szVal)
        case .sizeThenPosition:
            sOK = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, szVal)
            pOK = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posVal)
        }
        var readRef: CFTypeRef?
        var readBack: CGSize?
        if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &readRef) == .success,
           let v = readRef {
            var s = CGSize.zero
            // swiftlint:disable:next force_cast
            if AXValueGetValue(v as! AXValue, .cgSize, &s) { readBack = s }
        }
        if FrameWriteOrder.needsSizeReassert(target: frame, readBack: readBack) {
            sOK = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, szVal)
        }
        return pOK == .success && sOK == .success
    }

    /// Single-window CGWindowList attribute dict. `.optionIncludingWindow`
    /// can return more than the asked-for window, so the id filter is part
    /// of the idiom — shared here so it's maintained once.
    static func windowInfo(windowID: CGWindowID) -> [String: Any]? {
        let target = Int(windowID)
        guard let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID),
              let list = raw as? [[String: Any]] else { return nil }
        return list.first { ($0[kCGWindowNumber as String] as? Int) == target }
    }

    /// Live window bounds via CGWindowList — ground truth for probe
    /// read-backs. Reading AX (kAXPositionAttribute + kAXSizeAttribute)
    /// immediately after a write returns the JUST-WRITTEN value rather
    /// than the app-clamped actual — AX writes propagate asynchronously to
    /// the target app's NSWindow, and AX reads inside the same runloop
    /// tick return the cached requested value. CG bounds reflect what's
    /// actually on the framebuffer.
    static func cgBounds(windowID: CGWindowID) -> CGRect? {
        guard let info = windowInfo(windowID: windowID),
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
        else { return nil }
        return CGRect(
            x: Double(bounds["X"] ?? 0), y: Double(bounds["Y"] ?? 0),
            width: Double(bounds["Width"] ?? 0), height: Double(bounds["Height"] ?? 0)
        )
    }

    /// Probed variant of setFrame: after the write settles, reads back what
    /// the app actually accepted and runs it through the FrameLedger's
    /// verify: one automatic re-apply on mismatch, quantum learning for
    /// grid-snapping apps (Terminal cell rounding is convergence, not
    /// refusal), and a terminal `refused` verdict for apps that clamp the
    /// major geometry (Calculator, fixed-size dialogs). Async because the
    /// app-propagation wait is 60ms per read-back; asyncAfter keeps the main
    /// thread live instead of sleeping it.
    ///
    /// completion payload: { ok, actual: {x,y,w,h} | null, refused }.
    /// ok=false means the element wasn't reachable / the write failed;
    /// refusal is only meaningful when ok=true.
    static func settleProbe(
        windowID: CGWindowID,
        ok: Bool,
        x: Double, y: Double, w: Double, h: Double,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let targetFrame = CGRect(x: x, y: y, width: w, height: h)
        // One builder for the {ok, actual, refused} JS contract (pinned by
        // WindowsTests) — same local-payload pattern Spaces.moveWindow uses.
        func payload(actual: CGRect?, refused: Bool) -> [String: Any] {
            [
                "ok": ok,
                "actual": actual.map {
                    [
                        "x": Double($0.origin.x), "y": Double($0.origin.y),
                        "w": Double($0.size.width), "h": Double($0.size.height)
                    ] as [String: Any]
                } as Any? ?? NSNull(),
                "refused": refused
            ]
        }
        // Generation captured AFTER this probe's own write recorded: any
        // later write to the same window (next gesture step, a newer tile
        // pass, an animation tick) bumps it and this probe must not
        // re-apply its now-stale target on top. The retry re-captures —
        // its own re-apply is ours, not a supersede.
        func readBack(retriesLeft: Int, myGeneration: UInt64) {
            // 60ms app-propagation wait: reading CGWindowList immediately
            // catches an intermediate state where CG shows the requested
            // size before the app's layout pass clamps it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                guard let actual = cgBounds(windowID: windowID) else {
                    completion(payload(actual: nil, refused: false))
                    return
                }
                if FrameLedger.shared.generation(windowID: windowID) != myGeneration {
                    // A newer write owns the window; report what's on
                    // screen without verifying against OUR stale target —
                    // a mismatch here is expected, not a refusal.
                    completion(payload(actual: actual, refused: false))
                    return
                }
                let verdict = FrameLedger.shared.verify(
                    windowID: windowID, target: targetFrame, observed: actual)
                if verdict == .retry, retriesLeft > 0 {
                    _ = setFrame(windowID: windowID, x: x, y: y, w: w, h: h)
                    readBack(retriesLeft: retriesLeft - 1,
                             myGeneration: FrameLedger.shared.generation(windowID: windowID))
                    return
                }
                // A verdict still on .retry with no retries left counts as
                // refused — the write was re-applied and still didn't stick.
                completion(payload(actual: actual, refused: verdict == .refused || verdict == .retry))
            }
        }
        readBack(retriesLeft: 1, myGeneration: FrameLedger.shared.generation(windowID: windowID))
    }

    @discardableResult
    static func minimize(windowID: CGWindowID, _ value: Bool) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        let ok = AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, value as CFTypeRef) == .success
        if ok && value { WindowAnimationObserver.shared.noteMinimizing(windowID: windowID) }
        return ok
    }

    @discardableResult
    static func fullscreen(windowID: CGWindowID, _ value: Bool) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        return AXUIElementSetAttributeValue(el, "AXFullScreen" as CFString, value as CFTypeRef) == .success
    }

    @discardableResult
    static func raise(windowID: CGWindowID) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        return AXUIElementPerformAction(el, kAXRaiseAction as CFString) == .success
    }

    /// Focus = front the owning app with this window key, then raise it.
    ///
    /// SkyLight path (yabai's shape): _SLPSSetFrontProcessWithOptions with
    /// the window id and kCPSUserGenerated fronts the app at window-server
    /// level without waiting on the app's own activation; a synthetic
    /// press+release event record makes the window key; AXRaise + AXMain
    /// run on the app's AX queue, not main. A window of the app that is
    /// already frontmost raises at once (fronting its own app is a no-op
    /// there and the raise is what moves key focus); another app's window
    /// raises once its activation has settled.
    ///
    /// Fallback when the SPI is missing or refuses: NSRunningApplication
    /// activation plus synchronous AXRaise / AXMain / AXFocused on main.
    ///
    /// Divergence from hs.window:focus (becomeMain + SetFrontProcess with
    /// front-window-only, all synchronous): the raise lands asynchronously,
    /// so `true` means the window was fronted and made key, and a caller
    /// reading z-order right after may see the raise still pending.
    @discardableResult
    static func focus(windowID: CGWindowID) -> Bool {
        guard let pid = ownerPID(windowID: windowID) else { return false }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let route = WindowFocusRoute.decide(skyLightAvailable: SkyLightFocus.available,
                                            targetPid: pid, frontmostPid: frontmost)
        if case .skyLight(let raiseAfter) = route,
           let el = elementFor(windowID: windowID, pid: pid),
           SkyLightFocus.front(pid: pid, windowID: windowID) {
            let raise = {
                AXUIElementPerformAction(el, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, true as CFTypeRef)
            }
            let queue = AXAppQueues.queue(for: pid)
            if raiseAfter > 0 {
                queue.asyncAfter(deadline: .now() + raiseAfter, execute: raise)
            } else {
                queue.async(execute: raise)
            }
            return true
        }
        return focusByActivation(windowID: windowID, pid: pid)
    }

    private static func focusByActivation(windowID: CGWindowID, pid: pid_t) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        guard let el = elementFor(windowID: windowID, pid: pid) else { return false }
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, true as CFTypeRef)
        return true
    }

    @discardableResult
    static func close(windowID: CGWindowID) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        var btnRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, "AXCloseButton" as CFString, &btnRef) == .success,
              let btn = btnRef else { return false }
        // swiftlint:disable:next force_cast
        let button = btn as! AXUIElement
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// Current frame from AX (in the same Cocoa coords sd.windows.all returns).
    static func frame(windowID: CGWindowID) -> CGRect? {
        guard let el = elementFor(windowID: windowID) else { return nil }
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef)
        var pt = CGPoint.zero
        var sz = CGSize.zero
        if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
        if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
        return CGRect(origin: pt, size: sz)
    }

    static func isMinimized(windowID: CGWindowID) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        var ref: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXMinimizedAttribute as CFString, &ref)
        return (ref as? Bool) ?? false
    }

    static func isFullscreen(windowID: CGWindowID) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        var ref: AnyObject?
        AXUIElementCopyAttributeValue(el, "AXFullScreen" as CFString, &ref)
        return (ref as? Bool) ?? false
    }

    /// Raw AX hints used by overlay/outline stacks to pick a corner radius
    /// in JS. The daemon returns:
    ///
    ///   - `toolbarPresent`: a child `AXRole == "AXToolbar"` exists
    ///   - `role`:           kAXRoleAttribute (e.g. "AXWindow", "AXScrollArea")
    ///   - `subrole`:        kAXSubroleAttribute (e.g. "AXStandardWindow",
    ///                       "AXSystemDialog") — nil if unset
    ///
    /// Stacks (windowscape outline, overlay-border) map these to the actual
    /// 26 / 16 / 0 radii that match Tahoe's WindowServer rounding. Centralizing
    /// the policy in the stack lets each consumer override (a stack drawing a
    /// debug rect doesn't need to match Apple's exact curve).
    ///
    /// AX timeout capped at 100ms so one unresponsive app can't stall a
    /// per-tick overlay loop. Returns nil keys (or empty dict) when the AX
    /// query fails — the daemon never invents data.
    static func cornerHints(windowID: CGWindowID) -> [String: Any] {
        guard let el = elementFor(windowID: windowID) else {
            return ["toolbarPresent": false, "role": NSNull(), "subrole": NSNull()]
        }
        AXUIElementSetMessagingTimeout(el, 0.1)
        let role    = axStringAttribute(el, kAXRoleAttribute)
        let subrole = axStringAttribute(el, kAXSubroleAttribute)
        let toolbarPresent = elementHasToolbar(el)
        return [
            "toolbarPresent": toolbarPresent,
            "role":           role    as Any? ?? NSNull(),
            "subrole":        subrole as Any? ?? NSNull()
        ]
    }

    // MARK: Curated AX readers
    //
    // Per-window AX properties exposed without making stacks round-trip through
    // `sd.ax.*` (raw AXUIElement handles). Each reader follows the same shape
    // as `frame(windowID:)` above — resolve the element via `elementFor`, cap
    // the messaging timeout so one unresponsive app can't stall a poll loop,
    // read the attribute, return. The setters (`minimize`, `fullscreen`)
    // already exist; these are the matching read-side surface.

    /// Window title (kAXTitle). Returns nil if AX is unavailable or the window
    /// has no title set (palettes/inspectors sometimes leave it empty).
    static func title(windowID: CGWindowID) -> String? {
        guard let el = elementFor(windowID: windowID) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.1)
        return axStringAttribute(el, kAXTitleAttribute)
    }

    /// AX role (kAXRole) — "AXWindow", "AXScrollArea", "AXSheet", "AXDialog", …
    /// Same string `cornerHints` returns; surfaced separately so stacks that
    /// only need role don't pay the children-walk cost.
    static func role(windowID: CGWindowID) -> String? {
        guard let el = elementFor(windowID: windowID) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.1)
        return axStringAttribute(el, kAXRoleAttribute)
    }

    /// AX subrole (kAXSubrole) — "AXStandardWindow", "AXSystemDialog",
    /// "AXFloatingWindow", … Returns nil if the window doesn't declare one
    /// (rare for top-level windows; common for non-window AX elements).
    static func subrole(windowID: CGWindowID) -> String? {
        guard let el = elementFor(windowID: windowID) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.1)
        return axStringAttribute(el, kAXSubroleAttribute)
    }

    /// pid-hinted subrole — skips the full CGWindowList walk the id-only
    /// form pays to recover the owner. For callers that already hold the
    /// pid (the CGS 1325 fast-create gate reads it from the same window's
    /// CG info dict).
    static func subrole(windowID: CGWindowID, pid: pid_t) -> String? {
        guard let el = elementFor(windowID: windowID, pid: pid) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.1)
        return axStringAttribute(el, kAXSubroleAttribute)
    }

    /// Standalone toolbar probe — same children-walk `cornerHints` performs.
    /// Useful for stacks that ONLY need toolbar presence (e.g. a chrome-height
    /// estimator) without also paying for role/subrole reads.
    static func hasToolbar(windowID: CGWindowID) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        AXUIElementSetMessagingTimeout(el, 0.1)
        return elementHasToolbar(el)
    }

    /// Curated `kAXSubrole == kAXStandardWindow` check. The single most common
    /// AX gate tilers and overlays make ("should I touch this window?"). Spares
    /// stacks from baking the subrole comparison into JS, and keeps it
    /// discoverable alongside `subrole(id)`. Matches `hs.window:isStandard()`.
    /// One spelling of "is this a standard window" for every consumer —
    /// nil (unreadable subrole) collapses to false.
    static func isStandardSubrole(_ subrole: String?) -> Bool {
        subrole == (kAXStandardWindowSubrole as String)
    }

    static func isStandard(windowID: CGWindowID) -> Bool {
        isStandardSubrole(subrole(windowID: windowID))
    }

    /// Batch reader — one AXUIElement lookup, all properties returned.
    /// Replaces 4-9 individual round-trips when a stack wants several
    /// curated readers for the same window (overlay-border at attach time:
    /// isStandard + cornerHints + frame + title — was 4 RPCs, now 1).
    ///
    /// Returns nil when the window is unaddressable. Each field is best-
    /// effort: a missing property is null/false, not a hard failure.
    static func info(windowID: CGWindowID) -> [String: Any]? {
        guard let el = elementFor(windowID: windowID) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.1)
        // frame
        var posRef: AnyObject?, sizeRef: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef)
        var pt = CGPoint.zero, sz = CGSize.zero
        if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
        if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize,  &sz) }
        let frame: [String: Int] = [
            "x": Int(pt.x), "y": Int(pt.y), "w": Int(sz.width), "h": Int(sz.height)
        ]
        // String attrs (nil → NSNull so JSON.stringify yields null)
        let titleVal:   Any = axStringAttribute(el, kAXTitleAttribute   as String) ?? NSNull()
        let roleVal:    Any = axStringAttribute(el, kAXRoleAttribute    as String) ?? NSNull()
        let subroleVal: Any = axStringAttribute(el, kAXSubroleAttribute as String) ?? NSNull()
        // Bool attrs
        var minRef: AnyObject?, fsRef: AnyObject?, mainRef: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXMinimizedAttribute as CFString, &minRef)
        AXUIElementCopyAttributeValue(el, "AXFullScreen" as CFString,        &fsRef)
        AXUIElementCopyAttributeValue(el, kAXMainAttribute as CFString,      &mainRef)
        let isMin = (minRef as? Bool) ?? false
        let isFs  = (fsRef  as? Bool) ?? false
        // hasToolbar — same AXToolbar probe as the curated reader.
        var toolbarRef: AnyObject?
        AXUIElementCopyAttributeValue(el, "AXToolbar" as CFString, &toolbarRef)
        let hasToolbar = toolbarRef != nil
        // isStandard derived from subrole
        let isStd = (subroleVal as? String) == (kAXStandardWindowSubrole as String)
        return [
            "frame":        frame,
            "title":        titleVal,
            "role":         roleVal,
            "subrole":      subroleVal,
            "isMinimized":  isMin,
            "isFullscreen": isFs,
            "isMain":       (mainRef as? Bool) ?? false,
            "isStandard":   isStd,
            "hasToolbar":   hasToolbar,
            "cornerHints":  cornerHints(windowID: windowID)
        ]
    }

    /// Traffic-light button frames in the same global, top-left-origin coord
    /// space as `frame()`. Returns nil when the window is unaddressable; each
    /// of `close` / `zoom` / `minimize` is `{x,y,w,h}` or NSNull when the
    /// button doesn't exist on this window (some panels and helper windows
    /// lack one or more dots). Used by stacks that want to intercept clicks
    /// on the native dots (e.g. windowscape routes the yellow dot to its
    /// snapshot subsystem instead of the OS genie).
    ///
    /// One AX lookup per button (three round-trips to the app) batched into
    /// a single RPC. AX timeout 100ms — same gate as `cornerHints` / `info`.
    static func buttonFrames(windowID: CGWindowID) -> [String: Any]? {
        guard let el = elementFor(windowID: windowID) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.1)
        func rect(_ attr: String) -> Any {
            var btnRef: AnyObject?
            guard AXUIElementCopyAttributeValue(el, attr as CFString, &btnRef) == .success,
                  let btn = btnRef else { return NSNull() }
            // swiftlint:disable:next force_cast
            let button = btn as! AXUIElement
            var posRef: AnyObject?, sizeRef: AnyObject?
            AXUIElementCopyAttributeValue(button, kAXPositionAttribute as CFString, &posRef)
            AXUIElementCopyAttributeValue(button, kAXSizeAttribute     as CFString, &sizeRef)
            var pt = CGPoint.zero, sz = CGSize.zero
            if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
            if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize,  &sz) }
            if sz.width <= 0 || sz.height <= 0 { return NSNull() }
            return [
                "x": Int(pt.x), "y": Int(pt.y),
                "w": Int(sz.width), "h": Int(sz.height)
            ] as [String: Int]
        }
        return [
            "close":    rect("AXCloseButton"),
            "zoom":     rect("AXZoomButton"),
            "minimize": rect("AXMinimizeButton")
        ]
    }

    /// Per-window tab list. Walks the window's direct children for an
    /// `AXTabGroup` (browsers, Finder, terminals all use it); returns
    /// `[{title, selected}]` from the tab group's `AXChildren` (typically
    /// `AXRadioButton`s, one per tab). Returns nil when the window has no
    /// AXTabGroup child — most windows. Returns an empty array if the
    /// AXTabGroup exists but contains no children. Mirrors `hs.window:tabs()`.
    ///
    /// Tight strategy (per plan §6.4): direct child only, no recursive walk.
    /// Apps that bury tabs deeper (Safari's custom AXGroup with "tabs" role
    /// description) fall through to nil — stacks that need that path use the
    /// `sd.ax.*` escape hatch.
    static func tabs(windowID: CGWindowID) -> [[String: Any]]? {
        guard let el = elementFor(windowID: windowID) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.1)
        guard let group = tabGroup(in: el) else { return nil }
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(group, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return [] }
        return children.map { child -> [String: Any] in
            let title = axStringAttribute(child, kAXTitleAttribute) ?? ""
            var valRef: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valRef)
            let selected: Bool
            if let n = valRef as? NSNumber { selected = n.intValue != 0 }
            else if let b = valRef as? Bool { selected = b }
            else { selected = false }
            return ["title": title, "selected": selected]
        }
    }

    /// Press the Nth tab in the window's `AXTabGroup`. Returns false if the
    /// window has no AXTabGroup child, the index is out of range, or the AX
    /// press action fails. Mirrors `hs.window:focusTab(n)`.
    @discardableResult
    static func focusTab(windowID: CGWindowID, index: Int) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        AXUIElementSetMessagingTimeout(el, 0.1)
        guard let group = tabGroup(in: el) else { return false }
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(group, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement],
              index >= 0, index < children.count else { return false }
        return AXUIElementPerformAction(children[index], kAXPressAction as CFString) == .success
    }

    /// Direct-child AXTabGroup lookup. Tight strategy — does not recurse.
    private static func tabGroup(in el: AXUIElement) -> AXUIElement? {
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children where axStringAttribute(child, kAXRoleAttribute) == (kAXTabGroupRole as String) {
            return child
        }
        return nil
    }

    private static func elementHasToolbar(_ el: AXUIElement) -> Bool {
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return false }
        for child in children where axStringAttribute(child, kAXRoleAttribute) == "AXToolbar" {
            return true
        }
        return false
    }

    private static func axStringAttribute(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}

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
        let now = current()
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
            WindowDebug.log("overlay-events: main=\(f.onMain) off-main=\(f.offMain) for-targets=\(f.forTargets) moved-off-main=\(f.movedOffMain) stepped=\(f.steppedOnMain)")
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

    private func current() -> [Int: Snap] {
        var out: [Int: Snap] = [:]
        for raw in Windows.all() {
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

enum WindowLifecycleFanout {
    private static var announcements = CreateAnnouncementLedger()

    /// Read-only view for the poll's missed-by-ax drift counter — the poll
    /// checks before calling onCreate so an already-announced create
    /// neither double-fires nor inflates the "AX missed this" log.
    static func announcedRecently(id: Int) -> Bool {
        announcements.announcedRecently(id: id, now: Date().timeIntervalSince1970)
    }

    static func fireCreated(host: StackHost?, snap: WindowsLifecycleObserver.Snap, attempt: Int = 0) {
        // Single-owner dedup at the funnel: announcers classify ("is this
        // a create at all?"); WHETHER it was already announced is decided
        // here, once. Retries (attempt > 0) are the same announcement.
        if attempt == 0,
           !announcements.shouldAnnounce(id: snap.id, now: Date().timeIntervalSince1970) {
            WindowDebug.log("created fan-out: wid=\(snap.id) already announced — deduped")
            return
        }
        let ids = Set(Windows.all().compactMap { $0["id"] as? Int })
        if WindowsPumpRetry.satisfied(ids: ids, expectation: .present(snap.id)) {
            dispatch(host: host, snap: snap, attempt: attempt)
            return
        }
        guard let delay = WindowsPumpRetry.delay(attempt: attempt) else {
            WindowDebug.log("created fan-out: wid=\(snap.id) (\(snap.app)) never appeared in Windows.all() after \(attempt) retries — firing anyway")
            dispatch(host: host, snap: snap, attempt: attempt)
            return
        }
        WindowDebug.log("created fan-out: wid=\(snap.id) not in Windows.all() yet — retry in \(Int(delay * 1000))ms")
        // Strong capture of `host` is fine: the chain is bounded (<1s) and
        // the StackHost lives for the daemon's lifetime anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            WindowLifecycleFanout.fireCreated(host: host, snap: snap, attempt: attempt + 1)
        }
    }

    private static func dispatch(host: StackHost?, snap: WindowsLifecycleObserver.Snap, attempt: Int) {
        WindowDebug.log("created fan-out: wid=\(snap.id) dispatch (attempt=\(attempt))")
        host?.pumpWindowsListForAllStacks()
        host?.bang(name: "sd.window.created", detail: WindowsLifecycleObserver.detail(snap))
    }
}

// MARK: - FrontmostWindowObserver: event-driven focus/title changes

/// Dedupe between the two app-activation triggers, CGS 1508 and
/// NSWorkspace's didActivateApplication: an activation runs only for a pid
/// other than the last one activated, so the second report of one switch
/// is a no-op.
struct FrontmostActivation {
    private(set) var lastPid: pid_t?

    mutating func shouldActivate(pid: pid_t) -> Bool {
        if pid == lastPid { return false }
        lastPid = pid
        return true
    }

    /// Seed with the app that is frontmost now (nil forgets).
    mutating func reset(to pid: pid_t?) {
        lastPid = pid
    }
}

/// When the frontmost app's focused window is read off main. Triggers (an
/// activation, an AX focused/main-window notification) request a read for
/// a pid; the newest requested pid is the target.
///
/// - One read in flight per pid. Requests that land while it runs coalesce
///   into one re-read, since the running read may predate the change.
/// - A read for a pid that is no longer the target is discarded.
/// - A read that finds no window gets ONE retry after `nilRetryDelay`: an
///   activation can land before the app's kAXFocusedWindowAttribute is
///   readable, and the app posts no AX notification when it becomes
///   readable (its focused window never changed within the app), so
///   without the retry the switch is lost. The retry's result is delivered
///   whatever it finds.
///
/// While `awaiting`, main-thread readers defer to the pending delivery
/// instead of reading AX themselves. Main-thread state.
struct FocusedReadSchedule {
    enum Next: Equatable {
        /// Push the result.
        case deliver
        /// A newer request arrived during the read; the read is restarted.
        case readAgain
        /// No window yet; call `retryDue` after `after`, with `token`.
        case retry(after: TimeInterval, token: UInt64)
        /// The pid is no longer the target; drop the result.
        case discard
    }

    static let nilRetryDelay: TimeInterval = 0.1

    private(set) var target: pid_t?
    private var inFlight: Set<pid_t> = []
    private var dirty: Set<pid_t> = []
    private var retried = false
    private var retryToken: UInt64 = 0
    private var retryScheduled = false

    var awaiting: Bool {
        guard let t = target else { return false }
        return inFlight.contains(t) || retryScheduled
    }

    /// A trigger wants `pid`'s focused window. True: start a read now.
    mutating func request(pid: pid_t) -> Bool {
        target = pid
        retried = false
        retryScheduled = false
        retryToken &+= 1
        if inFlight.contains(pid) {
            dirty.insert(pid)
            return false
        }
        inFlight.insert(pid)
        return true
    }

    /// `pid`'s read finished; `found` is whether it named a window.
    mutating func resolved(pid: pid_t, found: Bool) -> Next {
        guard inFlight.remove(pid) != nil else { return .discard }
        let wasDirty = dirty.remove(pid) != nil
        guard pid == target else { return .discard }
        if wasDirty {
            inFlight.insert(pid)
            return .readAgain
        }
        if !found && !retried {
            retried = true
            retryScheduled = true
            retryToken &+= 1
            return .retry(after: Self.nilRetryDelay, token: retryToken)
        }
        return .deliver
    }

    /// The retry delay elapsed. True: start the retry read now.
    mutating func retryDue(pid: pid_t, token: UInt64) -> Bool {
        guard retryScheduled, token == retryToken, pid == target else { return false }
        retryScheduled = false
        if inFlight.contains(pid) { return false }
        inFlight.insert(pid)
        return true
    }

    mutating func reset() {
        self = FocusedReadSchedule()
    }
}

/// Singleton that maintains an AXAppObserver bound to whichever app is
/// currently frontmost. Event-driven, not polled — within-app focused-window
/// / title changes fire the moment AX reports them, with no polling lag.
///
/// Subscribers get a no-arg callback ("something focus-related changed,
/// re-query"). Bridge.startWorkspace already does the diff + push, so this
/// observer just needs to nudge.
///
/// Per-event-type fan-out: in addition to the union `fire()` that
/// drives the legacy `sd.windows.focused` channel, this observer exposes
/// separate `onAppActivated` / `onFocusedChanged` / `onTitleChanged`
/// closures. Bridge sets them once and they pump the granular channels
/// (`sd.app.activated`, `sd.windows.focusedChanged`, `sd.windows.titleChanged`)
/// without losing the existing union behavior.
final class FrontmostWindowObserver: RefCountedObserver {
    static let shared = FrontmostWindowObserver()
    private override init() { super.init() }

    private var currentTokens: [Token] = []
    private var activation = FrontmostActivation()
    private var reads = FocusedReadSchedule()

    /// Per-event-type callbacks. Multi-subscriber: every Bridge that calls
    /// startWorkspace appends its own handler; we fire ALL of them on each
    /// event. The original single-slot design assumed only one Bridge would
    /// ever set these, but in practice every stack with the "windows"
    /// permission gets its own Bridge that calls startWorkspace — the LAST
    /// to set the slot won, and all other stacks silently lost focusedChanged
    /// events. Symptom that surfaced this: overlay-border (the focused-
    /// window outline drawer) stopped following focus changes whenever any
    /// other "windows"-permission stack reloaded after it, because that
    /// stack's startWorkspace overwrote overlay-border's handler.
    ///
    /// Bridge calls append* on startWorkspace and detach via the returned
    /// Token in its scope drain. Each fires in addition to the union
    /// `fire()` so the legacy `sd.windows.focused` channel keeps working.
    private var appActivatedHandlers: [Int: () -> Void] = [:]
    private var focusedChangedHandlers: [Int: () -> Void] = [:]
    private var titleChangedHandlers:  [Int: () -> Void] = [:]
    private var nextHandlerId: Int = 1

    func appendAppActivated(_ fn: @escaping () -> Void) -> Token {
        let id = nextHandlerId; nextHandlerId += 1
        appActivatedHandlers[id] = fn
        return Token { [weak self] in self?.appActivatedHandlers.removeValue(forKey: id) }
    }
    func appendFocusedChanged(_ fn: @escaping () -> Void) -> Token {
        let id = nextHandlerId; nextHandlerId += 1
        focusedChangedHandlers[id] = fn
        return Token { [weak self] in self?.focusedChangedHandlers.removeValue(forKey: id) }
    }
    func appendTitleChanged(_ fn: @escaping () -> Void) -> Token {
        let id = nextHandlerId; nextHandlerId += 1
        titleChangedHandlers[id] = fn
        return Token { [weak self] in self?.titleChangedHandlers.removeValue(forKey: id) }
    }

    private func fireAppActivated()  { for fn in appActivatedHandlers.values  { fn() } }
    private func fireFocusedChanged(){ for fn in focusedChangedHandlers.values{ fn() } }
    private func fireTitleChanged()  { for fn in titleChangedHandlers.values  { fn() } }

    override func install() -> Token? {
        let ncToken = installNotifications([
            (NSWorkspace.shared.notificationCenter,
             NSWorkspace.didActivateApplicationNotification,
             { [weak self] note in
                 guard let self = self,
                       let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                 else { return }
                 self.activate(pid: app.processIdentifier)
             })
        ])
        // Install for current frontmost immediately so subscribers don't have
        // to wait for the next app switch.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let pid = front { installFor(pid: pid) }
        activation.reset(to: front)
        return Token { [weak self] in
            ncToken.cancel()
            guard let self = self else { return }
            self.activation.reset(to: nil)
            self.reads.reset()
            // Cancel the pool subscriptions so the AXObserverPool tears down
            // its per-pid AXAppObserver when this was the last subscriber —
            // matching the Token contract instead of waiting on deinit.
            for t in self.currentTokens { t.cancel() }
            self.currentTokens.removeAll()
        }
    }

    /// CGS 1508 named `pid` as the new frontmost app. It lands a few ms
    /// before didActivateApplication for the same switch; whichever comes
    /// first runs the activation. Main thread.
    func windowServerActivated(pid: pid_t) {
        guard isActive else { return }
        activate(pid: pid)
    }

    /// The app switch, once per new frontmost pid (FrontmostActivation).
    private func activate(pid: pid_t) {
        guard activation.shouldActivate(pid: pid) else { return }
        installFor(pid: pid)
        fireAppActivated()
        // The focused-window side of the switch (focusedChanged and the
        // union channel) waits for the confirmed read of this pid: a
        // main-thread read here would block on the app, and at CGS 1508
        // time NSWorkspace still names the previous app as frontmost.
        requestFocusedRead(pid: pid)
    }

    /// True while a confirmed read for the frontmost app is in flight or
    /// waiting on its retry; its delivery fires focusedChanged and the
    /// union channel, so main-thread readers skip rather than read AX.
    var awaitingFocusedRead: Bool { reads.awaiting }

    private func requestFocusedRead(pid: pid_t) {
        guard reads.request(pid: pid) else { return }
        startFocusedRead(pid: pid)
    }

    private func startFocusedRead(pid: pid_t) {
        AXAppQueues.queue(for: pid).async { [weak self] in
            let read = Windows.readFocusedWindow(pid: pid)
            DispatchQueue.main.async { self?.focusedReadResolved(pid: pid, read: read) }
        }
    }

    private func focusedReadResolved(pid: pid_t, read: Windows.FocusedWindowRead?) {
        switch reads.resolved(pid: pid, found: read != nil) {
        case .discard:
            return
        case .readAgain:
            startFocusedRead(pid: pid)
        case .retry(let delay, let token):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.reads.retryDue(pid: pid, token: token) else { return }
                self.startFocusedRead(pid: pid)
            }
        case .deliver:
            let payload = read.flatMap { r in
                NSRunningApplication(processIdentifier: pid).map { Windows.focusedPayload(r, app: $0) }
            }
            WorkspaceFanout.deliverFocused(payload)
            fireFocusedChanged()
            fire()
        }
    }

    private func installFor(pid: pid_t) {
        // Drop the previous app's pool subscriptions before subscribing to the
        // new pid so AXObserverPool can retire the old AXAppObserver if no
        // other consumers are using it.
        for t in currentTokens { t.cancel() }
        currentTokens.removeAll()

        // Route each AX notification to its dedicated callback. Focus and
        // main-window changes (the main window IS the focus target for most
        // apps) go through the confirmed off-main read, whose delivery fires
        // focusedChanged and the union nudge; title changes fire both now.
        let handler: (String) -> Void = { [weak self] notif in
            guard let self = self else { return }
            switch notif {
            case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
                self.requestFocusedRead(pid: pid)
            case kAXTitleChangedNotification:
                self.fireTitleChanged()
                self.fire()
            default:
                self.fire()
            }
        }
        for notif in [
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXTitleChangedNotification
        ] {
            if let t = AXObserverPool.observe(pid: pid, notification: notif as String, callback: handler) {
                currentTokens.append(t)
            }
        }
    }
}

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
//   - 1508 — frontmost app changed. Distinct from AX's
//            kAXFocusedWindowChangedNotification because 1508 fires on
//            user-driven app activation specifically (mouse click,
//            Cmd-Tab); AX focused-changed fires on programmatic focus too.
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
// stays the z-order backstop for any window the list misses.
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
    // Same wire format as the SpacesObserver in this file uses
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
//   1508 — frontmost app changed  (int32 pid at offset 0; surfaced as
//                                  sd.window.focusedByMouse and run as a
//                                  focus trigger ahead of NSWorkspace)
private let kSDWindowClosed:         UInt32 = 804
private let kSDWindowMoved:          UInt32 = 806
private let kSDWindowResized:        UInt32 = 807
private let kSDWindowReordered:      UInt32 = 808
private let kSDWindowTitleChanged:   UInt32 = 1322
private let kSDSpaceWindowCreated:   UInt32 = 1325
private let kSDSpaceWindowDestroyed: UInt32 = 1326
private let kSDWindowAnimationBegan: UInt32 = 1327
private let kSDWindowFocusedByMouse: UInt32 = 1508

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
    /// nil when the payload carries no usable pid.
    case frontmostByMouse(pid: pid_t?)
    case ignored
    case malformed
}

enum CGSWindowEventDecoder {
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
        case kSDWindowFocusedByMouse:
            guard let data = data, length >= 4 else { return .frontmostByMouse(pid: nil) }
            let pid = data.loadUnaligned(fromByteOffset: 0, as: Int32.self)
            return .frontmostByMouse(pid: pid > 0 ? pid : nil)
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
    // when OverlayEventFollow registered them, and are handled on this
    // thread before any hop.
    switch event {
    case .moved, .resized:
        OverlayEventFollow.handle(event)
        return
    case .spaceWindowDestroyed, .titleChanged, .ignored, .malformed:
        return
    default:
        WindowServerIntake.post(.window(event))
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
            scheduleFrameInterestRefresh()
            host.bang(name: "sd.window.destroyed", detail: ["id": Int(wid)])
        case .moved(let wid), .resized(let wid):
            // Only overlay targets get here: OverlayEventFollow drops
            // the rest in the callback.
            Overlay.followFrameEvent(wid: CGWindowID(wid))
        case .titleChanged:
            // Not registered; AX titleChanged covers titles.
            break
        case .spaceWindowCreated(let wid, _):
            handleSpaceWindowCreated(wid: wid, host: host)
        case .spaceWindowDestroyed:
            // Destroy rides 804; a space-move fires 1325 on the NEW
            // space, which re-pushes sd.spaces.all. Counted only.
            break
        case .frontmostByMouse(let pid):
            host.bang(name: "sd.window.focusedByMouse", detail: [:])
            if let pid = pid {
                FrontmostWindowObserver.shared.windowServerActivated(pid: pid)
            }
        case .animationBegan:
            WindowAnimationObserver.shared.animationBegan()
        case .ignored, .malformed:
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
        // Snap from CGWindowList; layer-0 standard candidates only. Title
        // via kCGWindowName is TCC-gated (screen recording) — empty is fine,
        // AX fills it in on its own create/titleChanged pass.
        guard let info = WindowsByID.windowInfo(windowID: cgWid),
              (info[kCGWindowLayer as String] as? Int) == 0,
              let pid = info[kCGWindowOwnerPID as String] as? Int
        else { return }
        // Before the subrole gate below, which needs AX for this app.
        WindowsAXObserver.shared.ensurePerWindow(pid: pid_t(pid), wid: cgWid)
        // Standard-window gate (positive verdict only): layer 0 alone
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
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
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

// =====================================================================
// MARK: - Per-window snapshot via SkyLight
// =====================================================================

// Per-window snapshot via SkyLight private SPI. Synchronous, no TCC prompt,
// and works for windows that are offscreen / minimized / on another space —
// the trick AltTab uses to render its live window-switcher grid.
//
// Distinct from Sources/DataSources/DisplaySnapshot.swift (which uses
// public ScreenCaptureKit for display capture): SCK can't grab a window
// the user hasn't currently exposed, and it triggers the Screen Recording
// TCC prompt. CGSHWCaptureWindowList has neither limitation but lives on
// private SkyLight; if the symbol vanishes in a future macOS, callers see
// nil and degrade.
//
// Stream / video variant is a separate ship — this is one-shot only.

private enum SkyLightWindowCapture {
    // CGSHWCaptureWindowList(cid, wids, count, options) → CFArrayRef of
    // CGImageRefs, one per requested window ID. options is a flag set;
    // (1 << 9) = nominal resolution (1x point size, no Retina upsample);
    // (1 << 11) = ignore the window's global clip shape (capture full
    // rectangular content, not just the visible region). Yabai and
    // JankyBorders both use the (nominal | ignore-clip) combo for the
    // sharpest, most predictable result.
    typealias HWCaptureWindowListFn = @convention(c) (
        Int32, UnsafePointer<UInt32>, Int32, UInt32
    ) -> Unmanaged<CFArray>?

    static let captureWindowList: HWCaptureWindowListFn? =
        SkyLight.sym("CGSHWCaptureWindowList")
}

extension WindowsByID {
    /// Snapshot a single window's current contents. `format` is "png"
    /// (default, lossless, larger payload) or "jpeg" (smaller, lossy).
    /// `quality` 0..1 applies to jpeg only — the canonical default lives in
    /// `Runtime/api.js` (`sd.windows.snapshot`), so this signature takes
    /// quality as-is. Returns
    ///   { dataURL, width, height }
    /// or nil if the SPI symbol resolves missing, the window id is invalid,
    /// or the encode fails. Works for hidden / minimized / off-space
    /// windows — the private SkyLight path doesn't gate on visibility.
    static func snapshot(windowID: CGWindowID,
                         format: String = "png",
                         quality: Double?) -> [String: Any]? {
        guard let capture = SkyLightWindowCapture.captureWindowList else { return nil }

        var wid = UInt32(windowID)
        let options: UInt32 = (1 << 11) | (1 << 9)
        guard let cfArr = capture(SkyLight.cid, &wid, 1, options)?.takeRetainedValue() else {
            return nil
        }
        let arr = cfArr as NSArray
        guard arr.count > 0 else { return nil }
        let cgImage = arr[0] as! CGImage

        return encode(image: cgImage, format: format, quality: quality)
    }

    /// CGImage → dataURL via CGImageDestination. Mirrors the encode path
    /// in CameraCapture.swift / VisionSubjectMask.swift — same UTI map,
    /// same base64 → "data:<mime>;base64,…" wrapping.
    private static func encode(image: CGImage,
                               format: String,
                               quality: Double?) -> [String: Any]? {
        let isPNG = (format == "png")
        let utType = (isPNG ? "public.png" : "public.jpeg") as CFString
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, utType, 1, nil
        ) else { return nil }
        // PNG ignores the quality dict; for JPEG, fall back to a baseline if
        // the caller (api.js) omits the field — but the canonical default is
        // declared in `sd.windows.snapshot` so this rarely fires.
        let props: [CFString: Any] = isPNG ? [:] : [
            kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality ?? 0.85))
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        let base64 = (data as Data).base64EncodedString()
        let mime = isPNG ? "image/png" : "image/jpeg"
        return [
            "dataURL": "data:\(mime);base64,\(base64)",
            "width":   image.width,
            "height":  image.height
        ]
    }
}

// =====================================================================
// MARK: - Spaces
// =====================================================================

// Per-display Spaces info via SkyLight private SPI. Same family of symbols
// hs.spaces uses (SLSCopyManagedDisplaySpaces, SLSSpaceGetType). Shared
// SkyLight loader lives in Sources/Private/SkyLight.swift; this enum just
// declares the symbol surface this domain needs.
private enum SkyLightSpaces {
    typealias CopyManagedSpacesFn    = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias SpaceGetTypeFn         = @convention(c) (Int32, UInt64) -> Int32
    typealias CopySpacesForWindowsFn = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?

    // uint64 SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef displayIdent)
    // — signature per Hammerspoon's hs.spaces. Takes the raw "Display
    // Identifier" string from the managed-displays snapshot (the literal
    // "Main" included) and returns the space id live from the window server,
    // where the snapshot's embedded "Current Space" can lag mid-switch.
    typealias DisplayGetCurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64

    // SLSRegisterConnectionNotifyProc(cid, callback, eventType, context). Used
    // for kCGSEvent space-life notifs that NSWorkspace doesn't surface. Yabai's
    // src/yabai.c is the reference for the exact signature.
    typealias CGSConnectionCallback = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
    typealias RegisterNotifyProcFn  = @convention(c) (Int32, CGSConnectionCallback, UInt32, UnsafeMutableRawPointer?) -> Int32

    // Write side (hs.spaces.moveWindowToSpace parity). Signatures per
    // yabai/src/misc/extern.h and Hammerspoon's hs.spaces implementation:
    //   void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef wids, uint64 sid)
    //   CGError SLSSpaceSetCompatID(int cid, uint64 sid, int workspace)
    //   CGError SLSSetWindowListWorkspace(int cid, uint32 *wids, int count, int workspace)
    typealias MoveWindowsToManagedSpaceFn = @convention(c) (Int32, CFArray, UInt64) -> Void
    typealias SpaceSetCompatIDFn          = @convention(c) (Int32, UInt64, Int32) -> Int32
    typealias SetWindowListWorkspaceFn    = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, Int32) -> Int32

    static let copyManagedSpaces:    CopyManagedSpacesFn?    = SkyLight.sym("SLSCopyManagedDisplaySpaces")
    static let spaceGetType:         SpaceGetTypeFn?         = SkyLight.sym("SLSSpaceGetType")
    static let displayGetCurrentSpace: DisplayGetCurrentSpaceFn? = SkyLight.sym("SLSManagedDisplayGetCurrentSpace")
    static let copySpacesForWindows: CopySpacesForWindowsFn? = SkyLight.sym("SLSCopySpacesForWindows")
    static let registerNotifyProc:   RegisterNotifyProcFn?   = SkyLight.sym("SLSRegisterConnectionNotifyProc")
    static let moveWindowsToManagedSpace: MoveWindowsToManagedSpaceFn? = SkyLight.sym("SLSMoveWindowsToManagedSpace")
    static let spaceSetCompatID:          SpaceSetCompatIDFn?          = SkyLight.sym("SLSSpaceSetCompatID")
    static let setWindowListWorkspace:    SetWindowListWorkspaceFn?    = SkyLight.sym("SLSSetWindowListWorkspace")
}

enum Spaces {
    /// Per-screen spaces info, keyed by NSScreen UUID:
    ///   { uuid: { displayID: int|undefined, spaces: [id, ...],
    ///            active: id|null, isFullscreen: bool } }
    /// displayID is the CGDirectDisplayID for the screen — pairs with the
    /// `display.id` field on sd.windows.focused (L2) and sd.mouse (R5.3),
    /// so consumers route by display id directly instead of joining UUIDs.
    static func all() -> [String: Any] {
        guard let copy = SkyLightSpaces.copyManagedSpaces,
              let getType = SkyLightSpaces.spaceGetType else {
            return [:]
        }
        let cid = SkyLight.cid
        guard let cfRef = copy(cid)?.takeRetainedValue() else { return [:] }
        let displays = cfRef as? [[String: Any]] ?? []

        // SkyLight identifies displays by either a UUID string or "Main" when
        // the "Displays Have Separate Spaces" preference is off. We rebuild a
        // UUID-keyed dict so the JS side is uniform regardless of that pref.
        let mainScreenUUID = NSScreen.screens.first.flatMap { screenUUID(for: $0) }

        // Per-screen displayID lookup so each entry can carry the CG display
        // id alongside the UUID key. Stacks routing by sd.windows.focused.
        // display.id (L2 enrichment) avoid a join against sd.display.all to
        // get the screen's identity — they index sd.spaces.all entries by
        // matching displayID directly.
        var displayIDByUUID: [String: Int] = [:]
        for screen in NSScreen.screens {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            if let uuid = screenUUID(for: screen), id != 0 {
                displayIDByUUID[uuid] = Int(id)
            }
        }

        return entries(
            displays: displays,
            mainScreenUUID: mainScreenUUID,
            displayIDByUUID: displayIDByUUID,
            currentSpace: { ident in
                SkyLightSpaces.displayGetCurrentSpace.map { $0(cid, ident as CFString) }
            },
            spaceType: { sid in getType(cid, sid) }
        )
    }

    /// Pure mapping from the SLSCopyManagedDisplaySpaces displays array to
    /// the per-UUID payload. `currentSpace` is queried with the RAW display
    /// identifier (before the "Main" remap — that's what the SLS call takes)
    /// and wins over the snapshot's embedded "Current Space" when it returns
    /// a nonzero id; the embedded value is the fallback for a missing symbol
    /// or a zero result.
    static func entries(displays: [[String: Any]],
                        mainScreenUUID: String?,
                        displayIDByUUID: [String: Int],
                        currentSpace: (String) -> UInt64?,
                        spaceType: (UInt64) -> Int32?) -> [String: Any] {
        var out: [String: Any] = [:]
        for disp in displays {
            let rawIdent = (disp["Display Identifier"] as? String) ?? ""
            var ident = rawIdent
            if ident == "Main", let main = mainScreenUUID { ident = main }
            let spacesArr = (disp["Spaces"] as? [[String: Any]]) ?? []

            var ids: [UInt64] = []
            for sp in spacesArr {
                if let n = sp["ManagedSpaceID"] as? NSNumber {
                    ids.append(n.uint64Value)
                }
            }
            var active = currentSpace(rawIdent).flatMap { $0 == 0 ? nil : $0 }
            if active == nil {
                let embedded = (disp["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber
                active = embedded?.uint64Value
            }

            // SLSSpaceGetType: 0 = user, 4 = fullscreen/tiled. Mirror hs.spaces.
            var isFullscreen = false
            if let a = active {
                isFullscreen = spaceType(a) == 4
            }

            var entry: [String: Any] = [
                "spaces":       ids.map { NSNumber(value: $0) },
                "active":       active.map { NSNumber(value: $0) } as Any? ?? NSNull(),
                "isFullscreen": isFullscreen
            ]
            if let did = displayIDByUUID[ident] { entry["displayID"] = did }
            out[ident] = entry
        }
        return out
    }

    private static func screenUUID(for screen: NSScreen) -> String? {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cf) as String?
    }

    /// Spaces the given window appears on, by CGWindowID. Backed by
    /// SLSCopySpacesForWindows (private SPI). Hammerspoon exposes this as
    /// hs.spaces.windowSpaces — tilers need it to know which space a window
    /// belongs to without trusting NSScreen-derived heuristics.
    static func windowSpaces(windowID: UInt32) -> [UInt64] {
        guard let fn = SkyLightSpaces.copySpacesForWindows else { return [] }
        let cid = SkyLight.cid
        // 0x7 covers all space-set masks (current, others, fullscreen, etc.)
        let arr: CFArray = [NSNumber(value: windowID)] as CFArray
        guard let cfRef = fn(cid, 0x7, arr)?.takeRetainedValue() else { return [] }
        let nums = (cfRef as? [NSNumber]) ?? []
        return nums.map { $0.uint64Value }
    }

    /// CGWindowIDs of all currently MINIMIZED windows on `spaceID`. Used by
    /// WindowScape's "where did I minimize this?" recall, and by future
    /// snapshot/restore code.
    ///
    /// Path chosen: CGWindowList(.optionAll) → filter `kCGWindowIsOnscreen == 0`
    /// → cross-reference each candidate with `windowSpaces(windowID:)`.
    /// SLSCopyWindowsWithOptionsAndTags is the more direct SLS route (yabai
    /// uses it with options=0x7 for "include minimized") but its set_tags /
    /// clear_tags out-parameter pair is easy to get wrong from Swift and the
    /// minimized bit isn't directly selectable — you'd still need a second
    /// pass against options=0x2 to subtract on-screen windows. The CG +
    /// windowSpaces route stays on public API for the heavy lift and only
    /// uses SLS for the per-window space lookup we already vend.
    static func minimizedWindows(spaceID: UInt64) -> [UInt32] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) else { return [] }
        let list = raw as! [[String: Any]]
        var out: [UInt32] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let num = info[kCGWindowNumber as String] as? Int else { continue }
            let onscreen = (info[kCGWindowIsOnscreen as String] as? Int) ?? 0
            if onscreen != 0 { continue }
            let wid = UInt32(num)
            if windowSpaces(windowID: wid).contains(spaceID) {
                out.append(wid)
            }
        }
        return out
    }

    /// Move a window to another user space — hs.spaces.moveWindowToSpace
    /// parity. Fullscreen/tiled target spaces (SLSSpaceGetType == 4) are refused,
    /// mirroring hs.spaces.
    ///
    /// Two routes, each verified via windowSpaces (the same SLS query
    /// sd.spaces.forWindow vends), because SLSMoveWindowsToManagedSpace
    /// silently stopped moving other-process windows on macOS 14.5:
    ///  A. SLSMoveWindowsToManagedSpace — the direct call.
    ///  B. yabai's workaround: tag the target space with a compat ID,
    ///     SLSSetWindowListWorkspace the window onto that workspace tag,
    ///     clear the tag.
    /// Returns { ok, spaces } where spaces is the VERIFIED post-move space
    /// list — callers update their caches from it instead of polling for
    /// convergence. ok=false leaves the window wherever it was.
    static func moveWindow(windowID: UInt32, toSpace spaceID: UInt64) -> [String: Any] {
        let cid = SkyLight.cid
        func payload(_ ok: Bool) -> [String: Any] {
            ["ok": ok,
             "spaces": windowSpaces(windowID: windowID).map { NSNumber(value: $0) }]
        }
        guard windowID != 0, spaceID != 0 else { return payload(false) }
        if let getType = SkyLightSpaces.spaceGetType, getType(cid, spaceID) == 4 {
            return payload(false)
        }
        func landed() -> Bool { windowSpaces(windowID: windowID).contains(spaceID) }
        if landed() { return payload(true) }

        if let move = SkyLightSpaces.moveWindowsToManagedSpace {
            move(cid, [NSNumber(value: windowID)] as CFArray, spaceID)
            if landed() { notifySpacesChanged(); return payload(true) }
        }
        if let setCompat = SkyLightSpaces.spaceSetCompatID,
           let setWorkspace = SkyLightSpaces.setWindowListWorkspace {
            // yabai's magic workspace tag ("yabe" in ASCII). Any nonzero
            // value works; matching yabai's keeps the two tools from
            // littering the space with distinct compat IDs.
            let compatTag: Int32 = 0x7961_6265
            _ = setCompat(cid, spaceID, compatTag)
            var wid = windowID
            _ = setWorkspace(cid, &wid, 1, compatTag)
            _ = setCompat(cid, spaceID, 0)
            if landed() { notifySpacesChanged(); return payload(true) }
        }
        return payload(false)
    }

    private static func notifySpacesChanged() {
        WindowServerIntake.post(.spaces)
    }
}

// CGS event types observed below. Yabai's src/yabai.c is the reference for
// which IDs are live on shipping macOS:
//   1327 — space created
//   1328 — space destroyed
//   1401 — space switched (fires AFTER the window server commits the change,
//          unlike NSWorkspace's activeSpaceDidChange which can arrive while
//          the managed-displays snapshot still holds the old space)
//   1204 — Mission Control entered (proxy for the user-driven space re-order
//          interaction that NSWorkspace's activeSpaceDidChange doesn't fire on
//          when no active-space change happens)
//
// The registration is deliberately process-lifetime — SLSRemoveConnectionNotifyProc
// exists (OmniWM binds it) but there's nothing worth tearing down. We guard
// registration with a static flag and route into the singleton; Token cancel
// only tears down the NSWorkspace / NSApplication observers (the CGS callback
// no-ops once SpacesObserver has no subscribers because fire() iterates an
// empty subs dict).
private let kCGSEventSpaceCreated:        UInt32 = 1327
private let kCGSEventSpaceDestroyed:      UInt32 = 1328
private let kCGSEventSpaceDidChange:      UInt32 = 1401
private let kCGSEventMissionControlEnter: UInt32 = 1204

private let spacesCGSCallback: SkyLightSpaces.CGSConnectionCallback = { eventType, _, _, _, _ in
    // A space switch posts several of these at once; the intake merges them
    // into one spaces pass per drain.
    WindowServerIntake.post(.spaces)
    // 1204 is the only CGS signal for "Mission Control entered" — exit is
    // an AX notification on the Dock, handled in MissionControl.swift.
    if eventType == kCGSEventMissionControlEnter {
        WindowServerIntake.post(.missionControlEntered)
    }
}

final class SpacesObserver: RefCountedObserver {
    static let shared = SpacesObserver()
    private override init() { super.init() }

    private static var cgsRegistered = false

    override func install() -> Token {
        // Screen reconfig can add/remove displays, which changes the keys —
        // observe alongside activeSpaceDidChange. Both go through the
        // intake so a switch's 1401 + activeSpaceDidChange + 1325s cost
        // one spaces pass per drain.
        let post: (Notification) -> Void = { _ in WindowServerIntake.post(.spaces) }
        let ncToken = installNotifications([
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification, post),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, post)
        ])

        if !SpacesObserver.cgsRegistered,
           let reg = SkyLightSpaces.registerNotifyProc {
            let cid = SkyLight.cid
            _ = reg(cid, spacesCGSCallback, kCGSEventSpaceCreated,        nil)
            _ = reg(cid, spacesCGSCallback, kCGSEventSpaceDestroyed,      nil)
            _ = reg(cid, spacesCGSCallback, kCGSEventSpaceDidChange,      nil)
            _ = reg(cid, spacesCGSCallback, kCGSEventMissionControlEnter, nil)
            SpacesObserver.cgsRegistered = true
        }

        return ncToken
    }
}

// =====================================================================
// MARK: - Mission Control AX bangs
// =====================================================================

// Mission Control state bangs.
//
// macOS gives the Mission Control transition out only through AX
// notifications on the Dock app (kAXExposeShowAllWindows, kAXExposeExit,
// etc.) — there is no public CG / NSWorkspace signal for "the user exited
// Mission Control" or for the show-front-windows / show-desktop variants.
// Reference: yabai's src/mission_control.c (mission_control_observe).
//
// Enter is handled separately in Sources/DataSources/Spaces.swift, where
// the CGS event 1204 callback already runs and now also fires
// `sd.missionControl.entered`. That keeps the Spaces subscription path
// authoritative for spaces, and lets this file focus on the AX side.
//
// Bangs surfaced (declared in a stack's `handles` array):
//   sd.missionControl.exited                — user exited Mission Control
//   sd.missionControl.shownAllWindows       — App Exposé "all windows"
//   sd.missionControl.shownFrontWindows     — App Exposé "front windows"
//   sd.missionControl.shownDesktop          — "Show Desktop" gesture
//
// Lifetime: installed once at startup from AppDelegate. The AXObserver lives
// for the process. Accessibility permission is required (stackd already
// declares it); if denied at startup we silently skip and retry on next
// install() call (idempotent — safe to re-invoke).

enum MissionControl {
    private static var installed = false
    private static var observerRef: AXObserver?
    private static var dockRef: AXUIElement?

    static func install() {
        guard !installed else { return }

        // Dock might be mid-restart during early daemon boot. If we miss it
        // we'll just retry on the next AppDelegate trigger (no scheduler here
        // because Dock restarts are rare — the user can /reload).
        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else {
            log("missionControl: Dock not running, skipping AX install")
            return
        }

        let pid = dockApp.processIdentifier
        let app = AXUIElementCreateApplication(pid)

        var observer: AXObserver?
        guard AXObserverCreate(pid, missionControlAXCallback, &observer) == .success,
              let observer = observer else {
            log("missionControl: AXObserverCreate failed (accessibility permission?)")
            return
        }

        // kAXExposeShowAllWindows / kAXExposeShowFrontWindows / kAXExposeShowDesktop
        // / kAXExposeExit are not in the Swift AX header constants — yabai uses
        // their raw CFString form. Same here.
        let notifs: [CFString] = [
            "AXExposeShowAllWindows" as CFString,
            "AXExposeShowFrontWindows" as CFString,
            "AXExposeShowDesktop" as CFString,
            "AXExposeExit" as CFString
        ]
        for n in notifs {
            let r = AXObserverAddNotification(observer, app, n, nil)
            if r != .success && r != .notificationAlreadyRegistered {
                log("missionControl: addNotification \(n) failed (\(r.rawValue))")
            }
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        observerRef = observer
        dockRef = app
        installed = true
    }
}

private let missionControlAXCallback: AXObserverCallback = { _, _, notification, _ in
    let name = notification as String
    let bang: String
    switch name {
    case "AXExposeExit":             bang = "sd.missionControl.exited"
    case "AXExposeShowAllWindows":   bang = "sd.missionControl.shownAllWindows"
    case "AXExposeShowFrontWindows": bang = "sd.missionControl.shownFrontWindows"
    case "AXExposeShowDesktop":      bang = "sd.missionControl.shownDesktop"
    default: return
    }
    DispatchQueue.main.async {
        AppDelegate.shared?.host?.bang(name: bang, detail: [:])
    }
}

// =====================================================================
// MARK: - WindowsAXObserver: per-app AXObserver for window lifecycle
// =====================================================================

// Primary source for `sd.window.created` / `sd.window.destroyed` /
// `sd.window.titleChanged` / `sd.window.moved` / `sd.window.resized` /
// `sd.window.minimized` / `sd.window.deminimized`.
//
/// Leading+trailing throttle keyed per (window, moved|resized). The
/// leading event .emits immediately and arms an 80ms gate; events
/// inside the gate .hold, and the coalescer keeps their `Source` (LAST
/// one wins); the trailing tick hands the held source back via
/// .emitHeld and re-arms, or .closes when the burst went quiet.
///
/// The source is what the caller reads the payload FROM (the window's
/// AXUIElement in production), not the payload itself: a held event is
/// never read, so a drag's in-window callbacks cost no AX round trips —
/// only the edges that actually dispatch do. Pure so the schedule is
/// testable — the caller (WindowsAXObserver.fireFrameBang) owns reads
/// and timers.
struct FrameBangCoalescer<Source> {
    enum Kind: String {
        case moved, resized
        var bangName: String { "sd.window.\(rawValue)" }
    }
    struct Key: Hashable {
        let windowID: CGWindowID
        let kind: Kind
    }
    enum EventAction: Equatable { case emit, hold }
    enum TickAction {
        case emitHeld(Source)
        case close
    }

    static var quietWindow: Double { 0.08 }

    private struct Gate {
        var until: Double
        var held: Source?
    }
    private var gates: [Key: Gate] = [:]

    mutating func onEvent(_ key: Key, now: Double, source: Source) -> EventAction {
        if var gate = gates[key], now < gate.until {
            gate.held = source
            gates[key] = gate
            return .hold
        }
        gates[key] = Gate(until: now + Self.quietWindow, held: nil)
        return .emit
    }

    mutating func onTick(_ key: Key, now: Double) -> TickAction {
        guard var gate = gates[key] else { return .close }
        if let held = gate.held {
            gate.held = nil
            gate.until = now + Self.quietWindow
            gates[key] = gate
            return .emitHeld(held)
        }
        // A tick that fires before the gate's deadline is stale — a
        // fresh leading edge re-armed the gate and scheduled its own
        // tick. Leave the gate for that one.
        if now >= gate.until { gates[key] = nil }
        return .close
    }

    mutating func purge(windowID: CGWindowID) {
        gates = gates.filter { $0.key.windowID != windowID }
    }
}

extension FrameBangCoalescer.TickAction: Equatable where Source: Equatable {}

// Per-app `AXObserver` (one per pid) listens for
// `kAXWindowCreatedNotification` on the application AXUIElement. On every
// new window we install a per-window observer for destroy / title / move /
// resize / miniaturize / deminiaturize — exactly the shape Hammerspoon's
// `hs.window.filter` uses (`window_filter.lua` + `axuielement/observer.m`)
// and yabai's `application_observe()` (`src/application.c`).
//
// Why this over a poll: the previous primary was a 1Hz CGWindowList diff
// (`WindowsLifecycleObserver`, below). CLAUDE.md rule: "Polling is the last
// resort, not the default — look for the event-driven primitive first." A
// live `hs -c` probe of Hammerspoon on the user's macOS 25.5.0 confirms AX
// observers deliver `windowCreated` / `windowDestroyed` reliably within ~1s
// of the action; we want the same.
//
// AX-trust gate: if the daemon hasn't been granted Accessibility, every
// `AXObserverCreate` returns `.cannotComplete` and no events fire. We log
// a clear stderr line at install time so the diagnosis is obvious; we do
// not auto-prompt (matches the rest of stackd's policy).
//
// Coexistence: still feeds the existing `WindowsLifecycleObserver.shared`
// callbacks set up in `AppDelegate.applicationDidFinishLaunching`, so the
// bang fan-out shape stays unchanged. The poll itself stays alive as a
// low-frequency safety backstop with a drift-sensor log when it
// catches an event AX missed.
final class WindowsAXObserver {
    static let shared = WindowsAXObserver()

    private var appObservers: [pid_t: AXAppObserver] = [:]
    private var appTokens: [pid_t: [Token]] = [:]
    // pid → wid → (window AXUIElement we observe + Tokens for the
    // per-window AXObserverAddNotification registrations). We hold the
    // window element so per-window AXObserverRemoveNotification can match
    // the original target when the app terminates or the window dies.
    private var windows: [pid_t: [CGWindowID: (element: AXUIElement, tokens: [Token])]] = [:] {
        didSet { WindowEvents.scheduleFrameInterestRefresh() }
    }

    /// Every wid holding per-window observers, ascending.
    var trackedWIDs: [UInt32] {
        windows.values.flatMap { $0.keys }.map { UInt32($0) }.sorted()
    }
    // Last seen title per (pid, wid). AX's titleChanged callback receives
    // the element but not the previous title; yabai/HS both cache. The
    // `sd.window.titleChanged` bang shape includes `oldTitle`, so stack
    // authors get the same payload from AX as from the polling fallback.
    private var lastTitle: [pid_t: [CGWindowID: String]] = [:]
    // Per-(pid, wid) last AX fire timestamp. The safety poll
    // cross-references this so it only logs "missed by AX" when AX has
    // genuinely been silent for the affected window.
    private(set) var lastAxFire: [CGWindowID: TimeInterval] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []

    private init() {}

    /// Install per-pid observers for every currently running window-hosting
    /// app, then hook NSWorkspace launch/terminate so we stay in sync as
    /// apps come and go. Idempotent — second call is a no-op.
    func install() {
        guard appObservers.isEmpty else { return }

        // AX trust must be granted for AXObserverCreate to succeed.
        // Prompt: true — every rebuild changes the ad-hoc cdhash and TCC
        // silently invalidates the previous grant, leaving a stale row in
        // System Settings that toggling does NOT re-associate with the new
        // binary. The system prompt is the one flow that binds the grant
        // to the binary actually running; it appears only when trust is
        // missing, so granted sessions never see it.
        let opts: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        if !trusted {
            log("ax: process not trusted for Accessibility — sd.window.* events will not fire (grant in System Settings → Privacy & Security → Accessibility)")
            // We still wire NSWorkspace so a later trust grant + relaunch
            // picks up new apps; per-app AX install will retry until it
            // succeeds via the launch-notification path.
        }

        // Daemon-startup seed: existing windows aren't "newly created"
        // from the user's perspective — they were there before we
        // launched. State replay for windowscape et al. comes via the
        // `sd.windows.all` channel (replayable). So we install observers
        // without firing onCreate for already-present windows.
        //
        // Retried, not one-shot: AX is slammed at daemon boot (every stack
        // probing at once) and AXObserverCreate / AXObserverAddNotification
        // can fail transiently for apps that would succeed seconds later. A
        // single silent failure here would mean EVERY event for that app
        // waits on the 10s safety poll for the daemon's lifetime.
        // fireForExisting stays false on retries too — a retry success
        // can't distinguish pre-daemon windows from during-retry ones, and
        // spurious creates for ancient windows are worse than the poll
        // catching a genuinely-new one late.
        for app in NSWorkspace.shared.runningApplications where shouldObserve(app) {
            installForAppRetry(app: app, delays: WindowsAXObserver.startupRetryDelays, fireForExisting: false)
        }

        let center = NSWorkspace.shared.notificationCenter
        // AX observer registrations and cached elements can go dead across
        // a sleep while their windows live on — no notification tells us.
        // Rebuild the AX layer once the system has settled after wake.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefreshAfterWake()
            })
        }
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // AX isn't always ready the moment didLaunch fires — yabai's
            // `application.c:93-96` retries on `kAXErrorCannotComplete`
            // after 100ms. Mirror that with a back-off ladder before
            // giving up. AX can also miss the kAXWindowCreatedNotification
            // for windows the app opens during the retry window —
            // `fireForExisting: true` rescues those by firing onCreate for
            // AXWindows present at install time. The 10s safety poll
            // catches whatever still slipped through and logs
            // `missed-by-ax` so a regression here can't hide.
            self?.installForAppRetry(app: app, delays: WindowsAXObserver.launchRetryDelays, fireForExisting: true)
        })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.uninstallForApp(pid: app.processIdentifier, appName: app.localizedName ?? "")
        })

        WindowDebug.log("ax: installed for \(appObservers.count) running apps (trusted=\(trusted))")
    }

    /// Cross-reference helper for the safety poll. Returns true if AX has
    /// fired for `wid` within `within` seconds — meaning the poll's diff
    /// is a stale read and should be silenced.
    func axFiredRecently(wid: CGWindowID, within: TimeInterval) -> Bool {
        guard let ts = lastAxFire[wid] else { return false }
        return (Date().timeIntervalSince1970 - ts) < within
    }

    /// Destroys already delivered to stacks (AX destroyed notification or
    /// CGS 804), so the safety poll doesn't fire them a second time.
    private var lastDestroyReported: [CGWindowID: TimeInterval] = [:]

    func noteDestroyReported(wid: CGWindowID) {
        lastDestroyReported[wid] = Date().timeIntervalSince1970
    }

    func destroyReportedRecently(wid: CGWindowID, within: TimeInterval) -> Bool {
        guard let ts = lastDestroyReported[wid] else { return false }
        return (Date().timeIntervalSince1970 - ts) < within
    }

    /// Drop lastAxFire entries older than `age`. Called from the safety
    /// poll's tick — the missed-by-ax gate only ever looks back ~12s, so
    /// anything older is dead weight that would otherwise accumulate one
    /// entry per wid for the daemon's lifetime.
    func pruneAxFireLog(olderThan age: TimeInterval) {
        let cutoff = Date().timeIntervalSince1970 - age
        lastAxFire = lastAxFire.filter { $0.value >= cutoff }
        lastDestroyReported = lastDestroyReported.filter { $0.value >= cutoff }
    }

    /// Owning pid for a wid we hold per-window observers on; nil when the
    /// wid isn't (or is no longer) tracked. Used by the CGS 804 destroy
    /// handler for targeted AX-cache invalidation — by the time 804 fires,
    /// the window is gone from CGWindowList so the pid can't be recovered
    /// there.
    func pidFor(wid: CGWindowID) -> pid_t? {
        for (pid, map) in windows where map[wid] != nil { return pid }
        return nil
    }


    // Install retry ladders. Launch path mirrors yabai's
    // kAXErrorCannotComplete retry (application.c:93-96) with tail entries
    // for slow-AX apps (Electron can take >1s to vend AXWindows). Startup
    // path starts slower — the daemon's own boot burst is the usual cause
    // of the first failure, and hammering AX during it makes things worse.
    static let launchRetryDelays:  [TimeInterval] = [0.1, 0.25, 0.5, 1.0, 2.0]
    static let startupRetryDelays: [TimeInterval] = [0.5, 1.0, 2.0]

    // MARK: - App lifecycle

    private func shouldObserve(_ app: NSRunningApplication) -> Bool {
        // .prohibited = background-only (no UI, no AX windows). .regular
        // (Dock+menubar) and .accessory (menubar-only) can still vend
        // AXWindows, so we observe both.
        app.activationPolicy != .prohibited && app.processIdentifier > 0
    }

    private var installRetryGate = AXInstallRetryGate()
    private var wakeRefreshWork: DispatchWorkItem?

    private func scheduleRefreshAfterWake() {
        wakeRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshAfterWake() }
        wakeRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Tear down every AX registration and cached element and install again
    /// from scratch — the daemon-startup path, minus firing creates.
    private func refreshAfterWake() {
        var windowCount = 0
        for pid in Array(appObservers.keys) {
            if let perWindow = windows.removeValue(forKey: pid) {
                windowCount += perWindow.count
                perWindow.values.forEach { $0.tokens.forEach { $0.cancel() } }
            }
            appTokens.removeValue(forKey: pid)?.forEach { $0.cancel() }
            appObservers.removeValue(forKey: pid)
        }
        let appCount = NSWorkspace.shared.runningApplications.filter(shouldObserve).count
        WindowsByID.invalidateAll()
        WindowAddressabilityCache.dropNonPositive()
        for app in NSWorkspace.shared.runningApplications where shouldObserve(app) {
            installForAppRetry(app: app, delays: WindowsAXObserver.startupRetryDelays, fireForExisting: false)
        }
        log("ax: refreshed after wake — \(appCount) apps, \(windowCount) windows re-observed")
        AppDelegate.shared?.host?.pumpWindowsListForAllStacks()
    }

    /// A window re-found without an AX create (safety poll, CGS 1325): make
    /// sure it has live per-window observers. The AX create notification
    /// never fires for a window that already existed, and an entry stored
    /// for an element that went dead (sleep/wake) would otherwise block
    /// re-installation — leaving the window with no moved/resized events.
    func ensurePerWindow(pid: pid_t, wid: CGWindowID) {
        guard let observer = appObservers[pid] else {
            ensureInstalled(pid: pid)
            return
        }
        let fresh = WindowsAXObserver.freshElement(appElement: observer.appElement, wid: wid)
        let decision = PerWindowInstallDecision.decide(
            existing: windows[pid]?[wid]?.element, fresh: fresh, same: { CFEqual($0, $1) })
        guard decision != .keep, let window = fresh else { return }
        if decision == .replace {
            windows[pid]?.removeValue(forKey: wid)?.tokens.forEach { $0.cancel() }
        }
        WindowsByID.invalidateCache(pid: pid, windowID: wid)
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        log("ax: per-window observers \(decision == .replace ? "replaced" : "attached") pid=\(pid) wid=\(wid) (\(app))")
        installPerWindow(pid: pid, app: app, window: window, firing: false)
    }

    /// The window's element as AX vends it right now — not the cached one.
    private static func freshElement(appElement: AXUIElement, wid: CGWindowID) -> AXUIElement? {
        guard let getWindow = AXShim.getWindow else { return nil }
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return nil }
        return arr.first { el in
            var w: CGWindowID = 0
            return getWindow(el, &w) == .success && w == wid
        }
    }

    /// A window appeared (CGS 1325) for an app we hold no AX observer on —
    /// its install exhausted the launch/startup ladder, typically on a
    /// transient failure while the daemon or the app was busy. Without a
    /// retry the app stays blind for the daemon's lifetime (new windows
    /// only surface via the 10s safety poll). Keyed off window creation, so
    /// windowless helper processes that also fail install never retry.
    func ensureInstalled(pid: pid_t) {
        guard appObservers[pid] == nil,
              installRetryGate.shouldAttempt(pid: pid, now: CFAbsoluteTimeGetCurrent()),
              let app = NSRunningApplication(processIdentifier: pid),
              shouldObserve(app) else { return }
        if installForApp(app: app, fireForExisting: false) {
            log("ax: install recovered pid=\(pid) (\(app.localizedName ?? "?")) on window create")
        }
    }

    private func installForAppRetry(app: NSRunningApplication, delays: [TimeInterval], fireForExisting: Bool) {
        guard shouldObserve(app) else { return }
        if installForApp(app: app, fireForExisting: fireForExisting) { return }
        guard let next = delays.first else {
            // Out of retries. The 10s safety poll still covers this app —
            // events arrive late instead of never — but that degradation
            // must be LOUD (plain log, not WindowDebug): a per-app install
            // failure is otherwise invisible until someone wonders why one
            // app's windows always tile ~10s behind.
            log("ax: install FAILED pid=\(app.processIdentifier) (\(app.localizedName ?? "?")) after all retries — its window events fall back to the 10s safety poll")
            return
        }
        let rest = Array(delays.dropFirst())
        DispatchQueue.main.asyncAfter(deadline: .now() + next) { [weak self] in
            self?.installForAppRetry(app: app, delays: rest, fireForExisting: fireForExisting)
        }
    }

    /// `fireForExisting`: when true, AXWindows already attached to the
    /// app at install time get treated as freshly-created and fire
    /// `onCreate` (the `didLaunchApplication` path uses this — the app
    /// may have opened windows during the AX-install retry window that
    /// we'd otherwise miss). When false, existing windows are seeded
    /// silently (the daemon-startup path uses this — those windows
    /// existed before us and replay through `sd.windows.all` instead).
    @discardableResult
    private func installForApp(app: NSRunningApplication, fireForExisting: Bool) -> Bool {
        let pid = app.processIdentifier
        let name = app.localizedName ?? ""
        if appObservers[pid] != nil { return true }
        guard let observer = AXAppObserver(pid: pid) else {
            WindowDebug.log("ax: install failed pid=\(pid) (\(name)) — AXObserverCreate returned error")
            return false
        }
        var tokens: [Token] = []

        if let t = observer.addWithElement(
            notification: kAXWindowCreatedNotification as String,
            callback: { [weak self] win, _ in self?.onWindowCreated(pid: pid, app: name, window: win) }
        ) {
            tokens.append(t)
        } else {
            // Without windowCreated the app observer is pointless — report
            // failure so the caller's retry ladder gets another shot
            // (AXObserverAddNotification fails with cannotComplete while an
            // app is still booting its AX server). Logged because a silent
            // nil here is the "registration accepted but never fires" class
            // of bug — except worse: the registration didn't even happen.
            WindowDebug.log("ax: addNotification windowCreated FAILED pid=\(pid) (\(name))")
            tokens.forEach { $0.cancel() }
            return false
        }
        if let t = observer.addWithElement(
            notification: kAXFocusedWindowChangedNotification as String,
            callback: { [weak self] win, _ in self?.onFocusedWindowChanged(pid: pid, app: name, window: win) }
        ) {
            tokens.append(t)
        } else {
            // Soft failure — windowCreated still covers lifecycle; we only
            // lose the early-install rescue path for first windows.
            WindowDebug.log("ax: addNotification focusedWindowChanged FAILED pid=\(pid) (\(name))")
        }

        appObservers[pid] = observer
        appTokens[pid] = tokens
        seedExistingWindows(pid: pid, app: name, appElement: observer.appElement, firing: fireForExisting)

        WindowDebug.log("ax: installed pid=\(pid) (\(name)) fireExisting=\(fireForExisting)")
        return true
    }

    private func uninstallForApp(pid: pid_t, appName: String = "") {
        appTokens.removeValue(forKey: pid)?.forEach { $0.cancel() }
        // When an app terminates, AX usually does NOT fire
        // `kAXUIElementDestroyedNotification` for its remaining windows —
        // the process is gone, and any queued AX events go with it. yabai
        // handles this by fanning out window-destroy from the
        // application-terminated path (`event_loop.c` APPLICATION_
        // TERMINATED). Mirror that here so windowscape sees a destroy
        // within the runloop tick of NSWorkspace.didTerminateApplication
        // instead of waiting for the 10s safety poll to notice.
        if let perWindow = windows.removeValue(forKey: pid) {
            let now = Date().timeIntervalSince1970
            for (wid, entry) in perWindow {
                entry.tokens.forEach { $0.cancel() }
                let title = lastTitle[pid]?[wid] ?? ""
                let snap = WindowsLifecycleObserver.Snap(
                    id: Int(wid), pid: Int(pid), app: appName, title: title, frame: .zero
                )
                lastAxFire[wid] = now
                WindowDebug.log("ax: app-terminate destroyed wid=\(wid)")
                WindowsLifecycleObserver.shared.onDestroy?(snap)
            }
        }
        lastTitle.removeValue(forKey: pid)
        appObservers.removeValue(forKey: pid)
        WindowDebug.log("ax: uninstalled pid=\(pid)")
    }

    private func seedExistingWindows(pid: pid_t, app: String, appElement: AXUIElement, firing: Bool) {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &raw) == .success,
              let cf = raw, CFGetTypeID(cf) == CFArrayGetTypeID() else { return }
        let arr = cf as! [AXUIElement]
        for win in arr {
            installPerWindow(pid: pid, app: app, window: win, firing: firing)
        }
    }

    // MARK: - Per-window handlers

    private func onWindowCreated(pid: pid_t, app: String, window: AXUIElement) {
        installPerWindow(pid: pid, app: app, window: window, firing: true)
    }

    // Re-check ladder for windows whose subrole read ERRORED at create time
    // (distinct from "read fine, not standard"). AX timeouts cluster at
    // exactly the moment windows are created — app launch, AX burst — and
    // kAXWindowCreated fires only once, so a dropped window here was
    // permanently invisible to the AX path until the 10s poll rescued it.
    static let subroleRetryDelays: [TimeInterval] = [0.25, 1.0]

    private func installPerWindow(pid: pid_t, app: String, window: AXUIElement, firing: Bool,
                                  subroleRetries: [TimeInterval] = WindowsAXObserver.subroleRetryDelays) {
        guard let observer = appObservers[pid] else { return }
        var w: CGWindowID = 0
        guard let getWindow = AXShim.getWindow, getWindow(window, &w) == .success, w != 0 else { return }
        let wid = w
        if windows[pid]?[wid] != nil { return }

        // Skip non-standard windows (Spotlight overlay, notification banners,
        // popover/sheet helpers, system HUDs). kAXSubrole == kAXStandardWindowSubrole
        // matches the `isStandard` filter `Windows.all()` already applies. Without
        // this gate the AX path fires create/destroy bangs and synthesizes
        // entries into `sd.windows.all` for windows the CGWindowList filter
        // would normally exclude (because their kCGWindowLayer is not 0),
        // and consumers like windowscape end up tiling them.
        //
        // Three-way verdict, not a bool: a subrole read that ERRORS (app
        // still constructing the window, AX timeout under load) must not be
        // conflated with "definitely not standard" — kAXWindowCreated won't
        // re-fire, so a wrong drop here is permanent. Unknown AND
        // un-minimized non-standard both get a bounded recheck before
        // giving up.
        let isMin = axWindowBool(window, kAXMinimizedAttribute as String) ?? false
        let verdict = axSubroleVerdict(window)
        switch verdict {
        case .standard:
            break
        case .nonStandard where isMin:
            // Minimized windows misreport their subrole (see
            // WindowAddressabilityCache.standardVerdict) — a Dock-parked
            // window reading AXDialog is still a real user window. Dropping
            // it here would skip its observers AND its cache seed, leaving
            // the probe to sticky-cache the same bogus non-standard verdict.
            break
        case .nonStandard, .unknown:
            // Neither reading is final. An errored read may be an app still
            // constructing the window or an AX timeout under load; an
            // un-minimized non-standard reading can be transitional (mid
            // minimize/deminimize the subrole still reads AXDialog while
            // AXMinimized has already flipped false). Recheck on the bounded
            // ladder — re-entry re-reads both subrole and AXMinimized; a
            // reading still non-standard once the ladder runs dry is a real
            // dialog/sheet and drops for good.
            let reading = verdict == .unknown ? "unreadable" : "non-standard"
            if let next = subroleRetries.first {
                let rest = Array(subroleRetries.dropFirst())
                WindowDebug.log("ax: subrole \(reading) pid=\(pid) wid=\(wid) — recheck in \(Int(next * 1000))ms")
                DispatchQueue.main.asyncAfter(deadline: .now() + next) { [weak self] in
                    guard let self = self, self.windows[pid]?[wid] == nil else { return }
                    self.installPerWindow(pid: pid, app: app, window: window, firing: firing, subroleRetries: rest)
                }
            } else {
                WindowDebug.log("ax: subrole stayed \(reading) pid=\(pid) wid=\(wid) — dropped after rechecks (10s poll is the backstop)")
            }
            return
        }

        // Seed the addressability cache with the AX-confirmed verdict.
        // Without this, `Windows.all()`'s probe for the brand-new wid lands
        // in the optimism grace (isStandard: false) whenever AX is busy —
        // filtering the window out of the exact snapshot AppDelegate pumps
        // in response to this create.
        WindowAddressabilityCache.confirm(pid: pid, windowID: wid, isStandard: true, isMinimized: isMin)

        let title = axWindowString(window, kAXTitleAttribute as String) ?? ""
        let frame = axWindowFrame(window) ?? .zero
        let snap = WindowsLifecycleObserver.Snap(
            id: Int(wid), pid: Int(pid), app: app, title: title, frame: frame
        )

        var tokens: [Token] = []
        let addPerWindow: (String, @escaping (AXUIElement) -> Void) -> Void = { notif, cb in
            if let t = observer.add(toElement: window, notification: notif, callback: { el, _ in cb(el) }) {
                tokens.append(t)
            } else {
                // Per-CLAUDE.md "verify the listener actually fires": a nil
                // token means AXObserverAddNotification refused — the event
                // type for this window will NEVER fire and only the 10s
                // poll covers it. Must be visible under STACKD_WIN_DEBUG.
                WindowDebug.log("ax: addNotification \(notif) FAILED pid=\(pid) wid=\(wid)")
            }
        }
        addPerWindow(kAXUIElementDestroyedNotification as String) { [weak self] _ in
            self?.onWindowDestroyed(pid: pid, wid: wid, app: app)
        }
        addPerWindow(kAXTitleChangedNotification as String) { [weak self] el in
            self?.onTitleChanged(pid: pid, wid: wid, app: app, window: el)
        }
        addPerWindow(kAXWindowMiniaturizedNotification as String) { [weak self] _ in
            self?.onMinimized(pid: pid, wid: wid)
        }
        addPerWindow(kAXWindowDeminiaturizedNotification as String) { [weak self] _ in
            self?.onDeminimized(pid: pid, wid: wid)
        }
        addPerWindow(kAXWindowMovedNotification as String) { [weak self] el in
            self?.onMoved(pid: pid, wid: wid, window: el)
        }
        addPerWindow(kAXWindowResizedNotification as String) { [weak self] el in
            self?.onResized(pid: pid, wid: wid, window: el)
        }

        windows[pid, default: [:]][wid] = (window, tokens)
        lastTitle[pid, default: [:]][wid] = title

        if firing {
            lastAxFire[wid] = Date().timeIntervalSince1970
            WindowDebug.log("ax: window created pid=\(pid) wid=\(wid) app=\(app) title='\(title)'")
            // No dedup here — WindowLifecycleFanout owns check-and-mark, so
            // a CGS 1325 that beat this AX create dedups at the funnel.
            WindowsLifecycleObserver.shared.onCreate?(snap)
        }
    }

    private func onWindowDestroyed(pid: pid_t, wid: CGWindowID, app: String) {
        let entry = windows[pid]?.removeValue(forKey: wid)
        entry?.tokens.forEach { $0.cancel() }
        let title = lastTitle[pid]?.removeValue(forKey: wid) ?? ""
        lastAxFire[wid] = Date().timeIntervalSince1970
        noteDestroyReported(wid: wid)
        WindowMotionEngine.shared.cancel(windowID: wid)
        FrameLedger.shared.clear(windowID: wid)
        dropFrameBangState(wid: wid)
        WindowDebug.log("ax: window destroyed pid=\(pid) wid=\(wid)")
        let snap = WindowsLifecycleObserver.Snap(
            id: Int(wid), pid: Int(pid), app: app, title: title, frame: .zero
        )
        WindowsLifecycleObserver.shared.onDestroy?(snap)
    }

    private func onTitleChanged(pid: pid_t, wid: CGWindowID, app: String, window: AXUIElement) {
        let newTitle = axWindowString(window, kAXTitleAttribute as String) ?? ""
        let oldTitle = lastTitle[pid]?[wid] ?? ""
        if newTitle == oldTitle { return }
        lastTitle[pid, default: [:]][wid] = newTitle
        let frame = axWindowFrame(window) ?? .zero
        let snap = WindowsLifecycleObserver.Snap(
            id: Int(wid), pid: Int(pid), app: app, title: newTitle, frame: frame
        )
        lastAxFire[wid] = Date().timeIntervalSince1970
        WindowDebug.log("ax: window title changed pid=\(pid) wid=\(wid) → '\(newTitle)'")
        WindowsLifecycleObserver.shared.onTitleChange?(snap, oldTitle)
    }

    private func onMinimized(pid: pid_t, wid: CGWindowID) {
        lastAxFire[wid] = Date().timeIntervalSince1970
        // Keep the cached isMinimized live BEFORE pumping — the probe's
        // sticky-success fast path never re-reads AX, so without this the
        // pumped sd.windows.all still carries the pre-minimize value.
        WindowAddressabilityCache.setMinimized(pid: pid, windowID: wid, true)
        WindowDebug.log("ax: window minimized pid=\(pid) wid=\(wid)")
        AppDelegate.shared?.host?.bang(name: "sd.window.minimized", detail: ["id": Int(wid)])
        AppDelegate.shared?.host?.pumpWindowsListForAllStacks()
    }

    private func onDeminimized(pid: pid_t, wid: CGWindowID) {
        lastAxFire[wid] = Date().timeIntervalSince1970
        WindowAddressabilityCache.setMinimized(pid: pid, windowID: wid, false)
        WindowDebug.log("ax: window deminimized pid=\(pid) wid=\(wid)")
        AppDelegate.shared?.host?.bang(name: "sd.window.deminimized", detail: ["id": Int(wid)])
        AppDelegate.shared?.host?.pumpWindowsListForAllStacks()
    }

    private func onMoved(pid: pid_t, wid: CGWindowID, window: AXUIElement) {
        fireFrameBang(.moved, wid: wid, window: window)
    }

    private func onResized(pid: pid_t, wid: CGWindowID, window: AXUIElement) {
        fireFrameBang(.resized, wid: wid, window: window)
    }

    /// Shared moved/resized dispatch: self-echo classification, then
    /// leading+trailing coalescing.
    ///
    /// While the motion engine is animating a window, its per-tick AX
    /// notifications are swallowed outright — they are our own writes by
    /// construction, and fanning 60–120 bangs/s/window through JSON →
    /// every-stack evaluateJavaScript is pure cost. The settle frame's
    /// trailing echoes arrive after the animation ends (AX lags writes by
    /// up to ~1s) and are delivered with `self: true` via the ledger, so
    /// stacks still observe the final geometry.
    ///
    /// Coalescing (hs.window.filter precedent — HS coalesces these too):
    /// the first event in a burst dispatches immediately so drag brackets
    /// wake promptly; events inside the 80ms quiet window only replace the
    /// held AXUIElement, and the frame is read once the trailing tick
    /// dispatches. A user drag emits (and reads AX) at ~12Hz instead of
    /// on every AX callback.
    private var frameBangCoalescer = FrameBangCoalescer<AXUIElement>()

    private func fireFrameBang(_ kind: FrameBangCoalescer<AXUIElement>.Kind, wid: CGWindowID, window: AXUIElement) {
        lastAxFire[wid] = Date().timeIntervalSince1970
        // Checked before the frame read: during an animation every tick
        // echoes back here, and the two synchronous AX reads would be
        // discarded anyway.
        if WindowMotionEngine.shared.isAnimating(windowID: wid) {
            WindowDebug.log("ax: \(kind.rawValue) swallowed (animating) wid=\(wid)")
            return
        }
        let key = FrameBangCoalescer<AXUIElement>.Key(windowID: wid, kind: kind)
        switch frameBangCoalescer.onEvent(key, now: CFAbsoluteTimeGetCurrent(), source: window) {
        case .emit:
            dispatchFrameBang(key, window: window)
            scheduleFrameBangTick(key)
        case .hold:
            break
        }
    }

    /// Reads the frame and classifies it against the ledger at dispatch
    /// time, so the echo check always sees the frame the bang carries.
    private func dispatchFrameBang(_ key: FrameBangCoalescer<AXUIElement>.Key, window: AXUIElement) {
        let frame = axWindowFrame(window) ?? .zero
        let isSelf = FrameLedger.shared.isSelf(
            windowID: key.windowID, observed: frame, now: CFAbsoluteTimeGetCurrent()
        )
        WindowDebug.log("ax: window \(key.kind.rawValue) wid=\(key.windowID) self=\(isSelf)")
        AppDelegate.shared?.host?.bang(name: key.kind.bangName, detail: [
            "id": Int(key.windowID),
            "self": isSelf,
            "frame": [
                "x": Int(frame.origin.x), "y": Int(frame.origin.y),
                "w": Int(frame.size.width), "h": Int(frame.size.height)
            ]
        ])
    }

    private func dropFrameBangState(wid: CGWindowID) {
        frameBangCoalescer.purge(windowID: wid)
    }

    private func scheduleFrameBangTick(_ key: FrameBangCoalescer<AXUIElement>.Key) {
        // +5ms past the quiet window so the tick lands on the far side of
        // the gate despite main-queue timer jitter.
        DispatchQueue.main.asyncAfter(deadline: .now() + FrameBangCoalescer<AXUIElement>.quietWindow + 0.005) { [weak self] in
            guard let self = self else { return }
            switch self.frameBangCoalescer.onTick(key, now: CFAbsoluteTimeGetCurrent()) {
            case .emitHeld(let window):
                self.dispatchFrameBang(key, window: window)
                self.scheduleFrameBangTick(key)
            case .close:
                break
            }
        }
    }

    private func onFocusedWindowChanged(pid: pid_t, app: String, window: AXUIElement) {
        var w: CGWindowID = 0
        guard let getWindow = AXShim.getWindow, getWindow(window, &w) == .success, w != 0 else { return }
        let wid = w
        // If this is a brand-new window we haven't seen, install
        // per-window observers (focusedWindowChanged commonly fires before
        // windowCreated for the first window of a freshly-launched app).
        if windows[pid]?[wid] == nil {
            installPerWindow(pid: pid, app: app, window: window, firing: true)
        }
        WindowDebug.log("ax: focused window pid=\(pid) wid=\(wid)")
        AppDelegate.shared?.host?.bang(name: "sd.window.focused", detail: ["id": Int(wid), "pid": Int(pid), "app": app])
    }

    // MARK: - AX helpers (window-scoped, to avoid colliding with the
    // app-scoped helpers used by FrontmostWindowObserver above)

    private func axWindowString(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Three-way subrole classification — same gate
    /// `WindowAddressabilityCache.probe` applies when enriching
    /// `Windows.all()`, but with the read-error case kept distinct so
    /// `installPerWindow` can retry instead of permanently dropping a
    /// window whose subrole read merely timed out.
    /// `.nonStandard` is a single-sample reading, not a final verdict: mid
    /// minimize/deminimize a real window reads AXDialog, so callers must
    /// recheck (or consult isMinimized) before dropping a window on it.
    private enum SubroleVerdict { case standard, nonStandard, unknown }

    private func axSubroleVerdict(_ el: AXUIElement) -> SubroleVerdict {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &ref) == .success,
              let s = ref as? String else { return .unknown }
        return s == (kAXStandardWindowSubrole as String) ? .standard : .nonStandard
    }

    private func axWindowBool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? Bool
    }

    private func axWindowFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posCF = posRef, let sizeCF = sizeRef else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(posCF as! AXValue, .cgPoint, &pt)
        AXValueGetValue(sizeCF as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
}
