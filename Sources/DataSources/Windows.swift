import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// SLSTransaction* — atomic batch of window geometry/order mutations committed
// to WindowServer in one round-trip. Used internally by sd.windows.batch
// (Bridge sets the batchSink and an opaque tx ref; WindowsByID.setFrame
// enqueues position moves into the tx instead of dispatching directly through
// AX) and consumed externally by Overlay.swift's per-tick reshape+order.
//
// Lives here (not in Sources/Private/SkyLight.swift) because the primary
// domain is windows; Overlay imports as `Windows.Transaction.*`. Mirrors
// Hammerspoon's per-extension SPI ownership.
//
// Signatures verified against yabai/src/misc/extern.h and JankyBorders/
// src/misc/extern.h. Position moves go through SLSTransactionMoveWindowWithGroup
// (CGPoint); size has to stay on AX (no SLSTransactionSetWindowSize exists)
// which is what actually constrains the window's frame anyway.
enum WindowTransaction {
    typealias CreateFn          = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    typealias CommitFn          = @convention(c) (CFTypeRef, Int32) -> Int32
    typealias MoveWithGroupFn   = @convention(c) (CFTypeRef, UInt32, CGPoint) -> Int32
    typealias OrderWindowFn     = @convention(c) (CFTypeRef, UInt32, Int32, UInt32) -> Int32
    typealias SetWindowLevelFn  = @convention(c) (CFTypeRef, UInt32, Int32) -> Int32

    static let create:         CreateFn?         = SkyLight.sym("SLSTransactionCreate")
    static let commit:         CommitFn?         = SkyLight.sym("SLSTransactionCommit")
    static let moveWithGroup:  MoveWithGroupFn?  = SkyLight.sym("SLSTransactionMoveWindowWithGroup")
    static let orderWindow:    OrderWindowFn?    = SkyLight.sym("SLSTransactionOrderWindow")
    static let setWindowLevel: SetWindowLevelFn? = SkyLight.sym("SLSTransactionSetWindowLevel")
}

// SLSCopyWindowsWithOptionsAndTags — yabai's authoritative window enumeration.
// CGWindowListCopyWindowInfo([.optionOnScreenOnly]) misses minimized + other-space
// + offscreen windows; this SLS call returns the full inventory and we then ask
// CGWindowListCreateDescriptionFromArray (public) for the attribute dicts.
// 6-arg signature matches shipping macOS (verified against yabai/window_manager.c).
// Falls back to CGWindowListCopyWindowInfo(.optionAll) if the symbol is missing.
private enum SkyLightWindowsEnum {
    typealias CopyWindowsFn = @convention(c) (
        Int32,                                // cid
        UInt32,                               // owner (0 = all owners)
        CFArray?,                             // spaces (nil = all spaces)
        UInt32,                               // options (0x2 includes minimized/offscreen)
        UnsafeMutablePointer<UInt64>,         // set_tags filter (0 = no filter)
        UnsafeMutablePointer<UInt64>          // clear_tags filter (0 = no filter)
    ) -> Unmanaged<CFArray>?

    static let copyWindows: CopyWindowsFn? = SkyLight.sym("SLSCopyWindowsWithOptionsAndTags")

    /// Authoritative window-id enumeration. Returns every window known to
    /// WindowServer matching `options` (0x2 = include minimized + offscreen).
    /// Returns nil if the SPI is unavailable so callers can take their own
    /// public-API fallback path.
    static func allWindowIDs(options: UInt32 = 0x2) -> [CGWindowID]? {
        guard let fn = copyWindows else { return nil }
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let cfRef = fn(SkyLight.cid, 0, nil, options, &setTags, &clearTags)?.takeRetainedValue() else {
            return nil
        }
        let nums = (cfRef as? [NSNumber]) ?? []
        return nums.map { CGWindowID($0.uint32Value) }
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
//   WindowsLifecycleObserver — polled (1Hz) CGWindowList diff that fires
//                              create/destroy/title-change callbacks. Lazy:
//                              the Timer only runs while a subscriber is live.
//
//   FrontmostWindowObserver  — event-driven AX notification fan-out for the
//                              focused app's focus / title changes. Rebinds
//                              its per-pid AXAppObserver on app activation.

// MARK: - Windows: CGWindowList + focused-window AX

enum Windows {
    // Focused window for the frontmost app, via Accessibility.
    static func focused() -> [String: Any]? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        // Cap blocking calls — an unresponsive app shouldn't hang the daemon.
        AXUIElementSetMessagingTimeout(appEl, 0.1)

        var focusedRef: AnyObject?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focusedRef)
        guard err == .success, let focused = focusedRef else { return nil }
        // swiftlint:disable:next force_cast
        let win = focused as! AXUIElement

        var titleRef: AnyObject?
        _ = AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""

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
        var idVal: Int? = nil
        if let getWindow = AXShim.getWindow, getWindow(win, &winId) == .success {
            idVal = Int(winId)
        }

        var out: [String: Any] = [
            "app": app.localizedName ?? "",
            "pid": Int(pid),
            "title": title,
            "frame": ["x": Int(pt.x), "y": Int(pt.y), "w": Int(sz.width), "h": Int(sz.height)]
        ]
        if let id = idVal { out["id"] = id }
        return out
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

    static func all(includeOwn: Bool = false) -> [[String: Any]] {
        // SLSCopyWindowsWithOptionsAndTags is the yabai-style "authoritative"
        // path but crashes inside SkyLight on macOS 26 (Tahoe) — repro: any
        // stack with `windows` permission segfaults at startWorkspace's
        // first push. Until the SPI signature is re-verified on Tahoe we
        // route through the public CGWindowListCopyWindowInfo only.
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) else { return [] }
        return decode(raw as! [[String: Any]], includeOwn: includeOwn)
    }

    private static func decode(_ list: [[String: Any]], includeOwn: Bool) -> [[String: Any]] {
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
            return [
                "id": num,
                "app": owner,
                "pid": pid,
                "title": info[kCGWindowName as String] as? String ?? "",
                "onscreen": onscreen != 0,
                "addressable": probe.addressable,
                "isStandard":  probe.isStandard,
                "isMinimized": probe.isMinimized,
                "frame": [
                    "x": Int(bounds["X"] ?? 0),
                    "y": Int(bounds["Y"] ?? 0),
                    "w": Int(bounds["Width"] ?? 0),
                    "h": Int(bounds["Height"] ?? 0)
                ]
            ]
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
// each one re-implementing per-pass probing (the previous design had
// windowscape doing 2N AX calls per tile pass — costly and racy).
enum WindowAddressabilityCache {
    struct Probe { let addressable: Bool; let isStandard: Bool; let isMinimized: Bool; let ts: TimeInterval }
    private static var cache: [String: Probe] = [:]
    // First-seen wall-time per (pid, windowID). A window gets a grace
    // window of OPTIMISTIC_GRACE_MS during which probe misses report
    // addressable=true (instead of false). Avoids the boot-burst race
    // where AX is slammed and Terminal's first 5+ probes time out in
    // milliseconds. Once the grace expires, real misses mark false.
    private static var firstSeenAt: [String: TimeInterval] = [:]
    private static let optimisticGraceMs: TimeInterval = 5.0
    private static let lock = NSLock()
    // Successful probes are cached PERMANENTLY (until pid death — see the
    // NSWorkspace.didTerminateApplication observer in install()). Reasoning:
    // AX's 100ms messaging timeout drops queries under load (spotlight
    // indexing, brightness poll, rapid tile passes); a once-addressable
    // window doesn't randomly become un-addressable while its pid is
    // alive. Re-probing on TTL expiry kept causing Terminal to lose its
    // verdict to a transient AX timeout.
    // Failed probes are re-checked aggressively so an app that JUST opened
    // a window gets re-evaluated within a beat.
    private static let failTtl: TimeInterval = 0.5

    static func probe(pid: pid_t, windowID: CGWindowID,
                      now: TimeInterval = Date().timeIntervalSince1970) -> Probe {
        let key = "\(pid)|\(windowID)"
        lock.lock()
        if let p = cache[key] {
            if p.addressable {
                lock.unlock()
                return p   // sticky success — never re-probe
            }
            if (now - p.ts) < failTtl {
                lock.unlock()
                return p
            }
        }
        lock.unlock()
        // Probe outside the lock — AX calls hop to main thread internally.
        let el = WindowsByID.elementFor(windowID: windowID, pid: pid)
        let addressable = (el != nil)
        var isStd = false
        var isMin = false
        if let e = el {
            var subroleRef: AnyObject?
            if AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &subroleRef) == .success,
               let s = subroleRef as? String {
                isStd = (s == (kAXStandardWindowSubrole as String))
            }
            var minRef: AnyObject?
            if AXUIElementCopyAttributeValue(e, kAXMinimizedAttribute as CFString, &minRef) == .success,
               let b = minRef as? Bool {
                isMin = b
            }
        }
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
            // transient miss. Keep addressable+isStandard, refresh isMinimized
            // (changes while window is alive — Cmd+M, dock click).
            probe = Probe(addressable: true, isStandard: e.isStandard, isMinimized: isMin, ts: now)
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
                probe = Probe(addressable: false, isStandard: false, isMinimized: false, ts: now)
                shouldCache = true
            }
        }
        if shouldCache { cache[key] = probe }
        lock.unlock()
        return probe
    }

    static func invalidate(pid: pid_t) {
        let prefix = "\(pid)|"
        lock.lock(); defer { lock.unlock() }
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        firstSeenAt = firstSeenAt.filter { !$0.key.hasPrefix(prefix) }
    }
}

// MARK: - AXShim: _AXUIElementGetWindow private SPI

enum AXShim {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static let getWindow: GetWindowFn? = {
        // _AXUIElementGetWindow is exported by ApplicationServices itself;
        // dlsym(RTLD_DEFAULT, ...) finds it without needing a framework path.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            FileHandle.standardError.write(Data("stackd: _AXUIElementGetWindow unavailable\n".utf8))
            return nil
        }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()
}

// MARK: - WindowsByID: per-window actions targeting a CGWindowID

enum WindowsByID {
    // Batch-mode mutation enum. When sd.windows.batch is active Bridge installs
    // a sink that funnels these into a live SLSTransaction; setFrame/raise on a
    // specific id route here instead of taking the direct AX path. Process-wide
    // because the sink + tx ref live on the static var below (one batch at a
    // time, serialized by Bridge.batch.begin refusing if one is already open).
    enum WindowMutation {
        case moveWithGroup(id: CGWindowID, point: CGPoint)
        case orderAbove(id: CGWindowID, relativeTo: CGWindowID)
    }

    static var batchSink: ((WindowMutation) -> Void)?
    private static var activeTransaction: CFTypeRef?

    // Opens a fresh SLSTransaction and installs a sink that funnels mutations
    // into it. Process-global — returns false if a batch is already open. Must
    // run on the WindowServer/main thread (same as AX). Pairs with commitBatch.
    @discardableResult
    static func beginBatch() -> Bool {
        if batchSink != nil { return false }
        guard let create = WindowTransaction.create,
              let move = WindowTransaction.moveWithGroup,
              let txRef = create(SkyLight.cid)?.takeRetainedValue() else {
            return false
        }
        activeTransaction = txRef
        batchSink = { mutation in
            switch mutation {
            case .moveWithGroup(let id, let point):
                _ = move(txRef, UInt32(id), point)
            case .orderAbove(let id, let rel):
                _ = WindowTransaction.orderWindow?(txRef, UInt32(id), 1, UInt32(rel))
            }
        }
        return true
    }

    @discardableResult
    static func commitBatch() -> Bool {
        guard let tx = activeTransaction else { return false }
        _ = WindowTransaction.commit?(tx, 0)
        batchSink = nil
        activeTransaction = nil
        return true
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

    // Look up by CGWindowID alone — we walk the CGWindowList to recover the
    // pid (cheap), then dispatch via elementFor(windowID:pid:).
    static func elementFor(windowID: CGWindowID) -> AXUIElement? {
        let target = Int(windowID)
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) else { return nil }
        let list = raw as! [[String: Any]]
        for info in list {
            if let n = info[kCGWindowNumber as String] as? Int, n == target,
               let p = info[kCGWindowOwnerPID as String] as? Int {
                return elementFor(windowID: CGWindowID(target), pid: pid_t(p))
            }
        }
        return nil
    }

    @discardableResult
    static func setFrame(windowID: CGWindowID, x: Double, y: Double, w: Double, h: Double) -> Bool {
        // Batch mode: AX still owns size (no SLS size symbol exists), but the
        // visible position pop is deferred until SLSTransactionCommit so every
        // window queued in this batch snaps to its new origin on a single
        // compositor flip. Size changes still cascade per-app (apps repaint at
        // their own pace) — that's the v1 tradeoff documented in the plan.
        if let sink = batchSink {
            guard let el = elementFor(windowID: windowID) else { return false }
            var sz = CGSize(width: w, height: h)
            guard let szVal = AXValueCreate(.cgSize, &sz) else { return false }
            _ = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, szVal)
            sink(.moveWithGroup(id: windowID, point: CGPoint(x: x, y: y)))
            return true
        }
        guard let el = elementFor(windowID: windowID) else { return false }
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

    /// Probed variant of setFrame: applies the requested geometry then reads
    /// back what AX/CG actually accepted, so callers (windowscape's tiler /
    /// drag-resize) can detect apps that refuse to honor the requested size.
    ///
    /// The read-back goes through CGWindowList, NOT AX. Reading AX
    /// (kAXPositionAttribute + kAXSizeAttribute) immediately after a write
    /// returns the JUST-WRITTEN value rather than the app-clamped actual —
    /// AX writes propagate asynchronously to the target app's NSWindow, and
    /// AX reads inside the same runloop tick return the cached requested
    /// value. CG bounds reflect what's actually on the framebuffer.
    ///
    /// Returns the post-set live frame; ok=false (with actual=null) means
    /// the element wasn't reachable. ok=true with actual ≠ requested means
    /// AX accepted the call but the app clamped the size (e.g. Calculator,
    /// fixed-size dialogs, Finder column widths).
    static func setFrameProbed(windowID: CGWindowID, x: Double, y: Double, w: Double, h: Double) -> [String: Any] {
        let ok = setFrame(windowID: windowID, x: x, y: y, w: w, h: h)
        // App propagation wait: AX writes hit the target app's runloop
        // asynchronously, then the app draws and CG updates. Reading
        // CGWindowList immediately catches an intermediate state where CG
        // shows the requested size before the app's layout pass clamps it.
        // 60ms is enough for most apps (Finder column rounding, Calculator
        // fixed size, browser min-width snap-backs) to settle. The cost is
        // tile-pass latency: 6 windows × 60ms = ~360ms per tile pass, which
        // is acceptable for a UX where tiles already animate at ~100ms.
        Thread.sleep(forTimeInterval: 0.06)
        // Read back via CGWindowList — ground truth, no AX cache race.
        let target = Int(windowID)
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], CGWindowID(windowID)
        ),
        let list = raw as? [[String: Any]],
        let info = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == target }),
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
        else {
            return ["ok": ok, "actual": NSNull()]
        }
        return [
            "ok": ok,
            "actual": [
                "x": Double(bounds["X"] ?? 0), "y": Double(bounds["Y"] ?? 0),
                "w": Double(bounds["Width"] ?? 0), "h": Double(bounds["Height"] ?? 0)
            ] as [String: Any]
        ]
    }

    @discardableResult
    static func minimize(windowID: CGWindowID, _ value: Bool) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        return AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, value as CFTypeRef) == .success
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

    // Focus = activate owning app + raise the window. Without the app
    // activation the window comes forward but the app keeps prior key state.
    @discardableResult
    static func focus(windowID: CGWindowID) -> Bool {
        let target = Int(windowID)
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) else { return false }
        let list = raw as! [[String: Any]]
        var foundPid: pid_t?
        for info in list {
            if let n = info[kCGWindowNumber as String] as? Int, n == target,
               let p = info[kCGWindowOwnerPID as String] as? Int {
                foundPid = pid_t(p); break
            }
        }
        guard let pid = foundPid else { return false }
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        guard let el = elementFor(windowID: CGWindowID(target), pid: pid) else { return false }
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

    /// Standalone toolbar probe — same children-walk `cornerHints` performs.
    /// Useful for stacks that ONLY need toolbar presence (e.g. a chrome-height
    /// estimator) without also paying for role/subrole reads.
    static func hasToolbar(windowID: CGWindowID) -> Bool {
        guard let el = elementFor(windowID: windowID) else { return false }
        AXUIElementSetMessagingTimeout(el, 0.1)
        return elementHasToolbar(el)
    }

    /// Curated `kAXSubrole == kAXStandardWindow` check. The single most common
    /// AX gate tilers and overlays make ("should I touch this window?"). Stacks
    /// previously baked the subrole comparison into JS; this one-liner makes
    /// it discoverable alongside `subrole(id)`. Matches `hs.window:isStandard()`.
    static func isStandard(windowID: CGWindowID) -> Bool {
        subrole(windowID: windowID) == (kAXStandardWindowSubrole as String)
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

// MARK: - WindowsLifecycleObserver: polled lifecycle events

// Polled window lifecycle: created / destroyed / titleChanged.
// Polling-based for v0 to avoid the AXObserver-per-app complexity. 1s tick
// is well within budget for UndoClose's use case (reopen recently closed)
// and any "recents" tracker. Architecturally identical fan-out to the
// AXObserver version — only the source of truth differs.
//
// Lazy: the 1Hz Timer only runs while at least one stack has subscribed
// (via subscribe(), typically because its manifest declares a sd.window.*
// handler). With no subscribers the daemon pays zero CPU here.
//
// AXObserver upgrade path is well-known if latency becomes an issue:
//   - per-pid AXObserver on kAXWindowCreatedNotification + per-window
//     observer on kAXUIElementDestroyedNotification & kAXTitleChangedNotification
//   - add/remove on NSWorkspace.{did{Launch,Terminate}Application}Notification
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

    private var snapshot: [Int: Snap] = [:]
    private var timer: Timer?
    // Subscriber-count gate. Token cancel decrements; 1→0 stops the timer.
    // AppDelegate sets the callbacks once at startup; subscribers are added
    // by StackHost when a stack's manifest declares `handles: ["sd.window.*"]`.
    private var subCount: Int = 0

    private init() {}

    /// Each subscribe() increments the live-subscriber count; the returned
    /// Token decrements on cancel. Adopting into a Bridge.scope means stack
    /// unload automatically releases it. The 1Hz Timer only runs while
    /// subCount > 0.
    func subscribe() -> Token {
        subCount += 1
        if subCount == 1 { start() }
        var released = false
        return Token { [weak self] in
            guard let self = self, !released else { return }
            released = true
            self.subCount = max(0, self.subCount - 1)
            if self.subCount == 0 { self.stop() }
        }
    }

    private func start() {
        guard timer == nil else { return }
        snapshot = current()        // seed without firing on first tick
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        snapshot.removeAll()
    }

    private func tick() {
        let now = current()
        for (id, info) in now {
            if let old = snapshot[id] {
                if old.title != info.title { onTitleChange?(info, old.title) }
            } else {
                onCreate?(info)
            }
        }
        for (id, info) in snapshot where now[id] == nil {
            onDestroy?(info)
        }
        snapshot = now
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

// MARK: - FrontmostWindowObserver: event-driven focus/title changes

/// Singleton that maintains an AXAppObserver bound to whichever app is
/// currently frontmost. Replaces the 1s `workspaceTimer` poll in Bridge —
/// within-app focused-window / title changes fire the moment AX reports
/// them, with no polling lag.
///
/// Subscribers get a no-arg callback ("something focus-related changed,
/// re-query"). Bridge.startWorkspace already does the diff + push, so this
/// observer just needs to nudge.
///
/// Per-event-type fan-out (F15): in addition to the union `fire()` that
/// drives the legacy `sd.windows.focused` channel, this observer exposes
/// separate `onAppActivated` / `onFocusedChanged` / `onTitleChanged`
/// closures. Bridge sets them once and they pump the granular channels
/// (`sd.app.activated`, `sd.windows.focusedChanged`, `sd.windows.titleChanged`)
/// without losing the existing union behavior.
final class FrontmostWindowObserver: RefCountedObserver {
    static let shared = FrontmostWindowObserver()
    private override init() { super.init() }

    private var currentTokens: [Token] = []

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
                 self.installFor(pid: app.processIdentifier)
                 // Activation itself counts as a focus change — fire so consumers
                 // pick up the new frontmost-app window without waiting for the
                 // first within-app AX notification.
                 self.fireAppActivated()
                 // Focus changes with the app switch — pump the focused-window
                 // channel too so stacks that only listen to focusedChanged
                 // don't miss the cross-app transition.
                 self.fireFocusedChanged()
                 self.fire()
             })
        ])
        // Install for current frontmost immediately so subscribers don't have
        // to wait for the next app switch.
        if let app = NSWorkspace.shared.frontmostApplication {
            installFor(pid: app.processIdentifier)
        }
        return Token { [weak self] in
            ncToken.cancel()
            guard let self = self else { return }
            // Cancel the pool subscriptions so the AXObserverPool tears down
            // its per-pid AXAppObserver when this was the last subscriber —
            // matching the Token contract instead of waiting on deinit.
            for t in self.currentTokens { t.cancel() }
            self.currentTokens.removeAll()
        }
    }

    private func installFor(pid: pid_t) {
        // Drop the previous app's pool subscriptions before subscribing to the
        // new pid so AXObserverPool can retire the old AXAppObserver if no
        // other consumers are using it.
        for t in currentTokens { t.cancel() }
        currentTokens.removeAll()

        // Route each AX notification to its dedicated callback before firing
        // the union nudge. kAXMainWindowChangedNotification is treated as a
        // focus change (the main window IS the focus target for most apps).
        let handler: (String) -> Void = { [weak self] notif in
            guard let self = self else { return }
            switch notif {
            case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
                self.fireFocusedChanged()
            case kAXTitleChangedNotification:
                self.fireTitleChanged()
            default:
                break
            }
            self.fire()
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
// MARK: - CGS window events (formerly Sources/DataSources/WindowEvents.swift)
// =====================================================================

// Window-level CGS notifications via SkyLight private SPI.
//
// Extends the connection-notify infrastructure already proven in
// Sources/DataSources/Spaces.swift (which subscribes to space-life events
// 1327/1328/1204). We use the sibling `SLSRegisterNotifyProc` entry point
// (not the per-connection variant) so we observe events for windows owned by
// other applications, matching JankyBorders' approach.
//
// Coexistence with WindowsLifecycleObserver (1Hz CGWindowList poll):
//   Both run. CGS fires earlier/faster than the poll; the poller is the
//   conservative backstop. Stack manifests subscribe via `handles: ["sd.window.*"]`
//   to whichever bang they care about — `sd.window.created` may fire from
//   either source first. The polling observer's per-tick diff sees an already-
//   existing window on the next tick and skips, so the duplicate is naturally
//   suppressed.
//
// Event-ID source of truth & verified availability:
//   The IDs below are taken from FelixKratz/JankyBorders (events.h) cross-
//   referenced with koekeishiya/yabai (yabai.c registers 808/1327/1328/1204
//   via SLSRegisterConnectionNotifyProc with the same wire format).
//
//   On macOS 26 (Tahoe) we have CONFIRMED, via the STACKD_CGS_DEBUG=1 dump
//   loop below, that these IDs fire reliably:
//
//     1325 — window created               (verified, payload {sid, wid})
//     1326 — window destroyed             (verified, payload {sid, wid})
//     1508 — frontmost app changed        (verified, empty payload — surfaced
//                                          as sd.window.focusedByMouse)
//     1327 — space created                (already wired in Spaces.swift;
//                                          ALSO fires on minimize on Tahoe
//                                          because each minimize creates a
//                                          per-window background space)
//
//   The remaining IDs (804/806/807/808/815/816) were live on Sequoia and
//   earlier but DO NOT fire on Tahoe as of macOS 26.5. The Tahoe equivalent
//   appears to ride generic mouse-event IDs 718/719 with a 248-byte payload
//   that does NOT carry a CGWindowID at offset 0 — that's an input-tap
//   surface, not a per-window CGS event. Registrations for the missing IDs
//   are kept below as no-ops so they Just Work if a future macOS release
//   re-exposes them; symptom of "missing" today is silent no-fire.
//
//   To rediscover IDs after a macOS bump: launch the daemon with
//   STACKD_CGS_DEBUG=1; every event in [700, 2000) is logged to stderr with
//   ID + first 32 bytes of payload. Trigger the action you want to map,
//   look for an event whose hex payload starts with the affected window's
//   CGWindowID in little-endian.

private enum SkyLightWindowEvents {
    // SLSRegisterNotifyProc — JankyBorders/yabai use this for per-window
    // events. Callback signature: (event, data, dataLength, context). NO
    // connection id is passed (unlike SLSRegisterConnectionNotifyProc which
    // we use for space events in Spaces.swift). This is the right entry
    // point for events that should fire globally for ALL windows of ALL
    // applications, not just our own connection.
    typealias CGSNotifyCallback     = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    typealias RegisterNotifyProcFn  = @convention(c) (CGSNotifyCallback, UInt32, UnsafeMutableRawPointer?) -> Int32

    static let registerNotifyProc: RegisterNotifyProcFn? = SkyLight.sym("SLSRegisterNotifyProc")
}

// CGS window event IDs. JankyBorders/events.h is the canonical reference for
// the names; macOS 26.5 (Tahoe) availability per the STACKD_CGS_DEBUG dump.
//   804  — window closed         (Sequoia-/no-fire on Tahoe; payload: uint32 wid)
//   806  — window moved          (Sequoia-/no-fire on Tahoe; payload: uint32 wid)
//   807  — window resized        (Sequoia-/no-fire on Tahoe; payload: uint32 wid)
//   808  — window reordered      (Sequoia-/no-fire on Tahoe; payload: uint32 wid)
//   815  — window deminimized    (Sequoia-/no-fire on Tahoe; payload: uint32 wid)
//   816  — window minimized      (Sequoia-/no-fire on Tahoe; payload: uint32 wid)
//   1325 — window created        (ACTIVE on Tahoe; payload: { uint64 sid; uint32 wid })
//   1326 — window destroyed      (ACTIVE on Tahoe; payload: { uint64 sid; uint32 wid })
//   1508 — frontmost app changed (ACTIVE on Tahoe; no payload; surfaced as
//                                 sd.window.focusedByMouse since front-change
//                                 is the closest stable signal for "user
//                                 clicked to focus a different window" — the
//                                 nominal 1300/kCGSEventWindowFocusedByMouse
//                                 doesn't fire on current macOS)
private let kSDWindowClosed:        UInt32 = 804
private let kSDWindowMoved:         UInt32 = 806
private let kSDWindowResized:       UInt32 = 807
private let kSDWindowReordered:     UInt32 = 808
private let kSDWindowDeminimized:   UInt32 = 815
private let kSDWindowMinimized:     UInt32 = 816
private let kSDWindowCreated:       UInt32 = 1325
private let kSDWindowDestroyed:     UInt32 = 1326
private let kSDWindowFocusedByMouse: UInt32 = 1508

// The shared callback. SkyLight invokes us off the main thread; we hop to main
// before touching AppDelegate.shared / host so bang dispatch and WebView fan-out
// stay on the runloop they were built on.
//
// Payload decode rules:
//   - Create / Destroy (1325/1326): { uint64_t sid; uint32_t wid; }
//   - Front-change (1508): no payload data we use
//   - All other window events: uint32_t wid at offset 0
//
// dataLen is always >= the size we read; we sanity-check before dereferencing
// because SkyLight has been known to fire callbacks with zero-length payloads
// during edge cases (e.g. a window getting created+destroyed in the same tick).
private let windowEventsCallback: SkyLightWindowEvents.CGSNotifyCallback = { eventType, data, dataLen, _ in
    // Front-change has no useful payload; just fire the bang.
    if eventType == kSDWindowFocusedByMouse {
        DispatchQueue.main.async {
            AppDelegate.shared?.host?.bang(name: "sd.window.focusedByMouse", detail: [:])
        }
        return
    }

    // Create / Destroy carry a {sid, wid} struct. wid is at offset 8.
    if eventType == kSDWindowCreated || eventType == kSDWindowDestroyed {
        guard let data = data, dataLen >= 12 else { return }
        let wid = data.advanced(by: 8).load(as: UInt32.self)
        WindowEvents.handleSpawn(eventType: eventType, wid: wid)
        return
    }

    // All remaining window events start with a uint32_t wid.
    guard let data = data, dataLen >= 4 else { return }
    let wid = data.load(as: UInt32.self)
    WindowEvents.handleModify(eventType: eventType, wid: wid)
}

// Debug logger: prints every event ID + first 32 bytes of payload to stderr.
// Active only when STACKD_CGS_DEBUG=1. Used to verify event-ID mappings after
// a macOS version bump.
private let debugWindowEventsCallback: SkyLightWindowEvents.CGSNotifyCallback = { event, data, dataLen, _ in
    var hex = ""
    if let data = data, dataLen > 0 {
        let lim = min(dataLen, 32)
        for i in 0..<lim {
            hex += String(format: "%02x ", data.advanced(by: i).load(as: UInt8.self))
        }
    }
    FileHandle.standardError.write(Data("stackd-cgs: event=\(event) len=\(dataLen) [\(hex)]\n".utf8))
}

enum WindowEvents {
    private static var cgsRegistered = false

    /// Install the CGS callbacks. Idempotent; safe to call from AppDelegate.
    /// SkyLight has no removeNotifyProc, so registration lives for the lifetime
    /// of the process — matches the SpacesObserver pattern.
    static func install() {
        guard !cgsRegistered, let reg = SkyLightWindowEvents.registerNotifyProc else { return }
        // Only register events that ACTUALLY fire on the current macOS.
        // Per the kSDWindow* comment block, 804/806/807/808/815/816 are
        // documented as "Sequoia-/no-fire on Tahoe" — TahoeSynthPoll covers
        // those via CG diff. Keeping the registration calls created dead
        // callbacks the OS still bookkeeps. Created/destroyed/focusedByMouse
        // do fire on Tahoe, so those stay.
        for evt in [
            kSDWindowCreated,
            kSDWindowDestroyed,
            kSDWindowFocusedByMouse
        ] {
            _ = reg(windowEventsCallback, evt, nil)
        }
        // Debug-watcher: STACKD_CGS_DEBUG=1 registers a logger for every event
        // ID in [700, 2000) so we can rediscover IDs after a macOS shift.
        // Mirrors the JankyBorders debug loop in src/events.c.
        if ProcessInfo.processInfo.environment["STACKD_CGS_DEBUG"] != nil {
            for i in UInt32(700)..<UInt32(2000) {
                _ = reg(debugWindowEventsCallback, i, nil)
            }
        }
        cgsRegistered = true
    }

    // MARK: - Bang fan-out

    /// Per-window bangs that just need an id. Frame is recovered via
    /// WindowsByID.frame(windowID:) for move/resize so consumers don't have to
    /// query separately; for the others id alone is enough.
    fileprivate static func handleModify(eventType: UInt32, wid: UInt32) {
        DispatchQueue.main.async {
            guard let host = AppDelegate.shared?.host else { return }

            switch eventType {
            case kSDWindowMoved:
                var d: [String: Any] = ["id": Int(wid)]
                if let f = WindowsByID.frame(windowID: CGWindowID(wid)) {
                    d["frame"] = frameDict(f)
                }
                host.bang(name: "sd.window.moved", detail: d)

            case kSDWindowResized:
                var d: [String: Any] = ["id": Int(wid)]
                if let f = WindowsByID.frame(windowID: CGWindowID(wid)) {
                    d["frame"] = frameDict(f)
                }
                host.bang(name: "sd.window.resized", detail: d)

            case kSDWindowReordered:
                host.bang(name: "sd.window.reordered", detail: ["id": Int(wid)])

            case kSDWindowMinimized:
                host.bang(name: "sd.window.minimized", detail: ["id": Int(wid)])

            case kSDWindowDeminimized:
                host.bang(name: "sd.window.deminimized", detail: ["id": Int(wid)])

            case kSDWindowClosed:
                // Treat 804 as a destroyed-window signal so consumers don't
                // have to track two near-identical events. The polling
                // WindowsLifecycleObserver will independently fire its own
                // sd.window.destroyed on next tick — host.bang's per-stack
                // dedup is the stack author's responsibility, but in practice
                // the polling diff sees the window already gone and skips.
                WindowsByID.invalidateAll()
                host.bang(name: "sd.window.destroyed", detail: ["id": Int(wid)])

            default:
                break
            }
        }
    }

    /// Create/Destroy carry a window id; we look up app/pid/title via
    /// CGWindowListCopyWindowInfo filtered by kCGWindowNumber so the detail
    /// matches the polling observer's payload shape.
    fileprivate static func handleSpawn(eventType: UInt32, wid: UInt32) {
        DispatchQueue.main.async {
            guard let host = AppDelegate.shared?.host else { return }

            switch eventType {
            case kSDWindowCreated:
                let detail = detailForWindow(wid: wid)
                host.bang(name: "sd.window.created", detail: detail)

            case kSDWindowDestroyed:
                // The window is already gone — CGWindowList lookup will miss.
                // Emit just the id; consumers that need the prior title/app
                // should cache from the create event. Mirrors yabai's
                // SLS_WINDOW_DESTROYED handler.
                WindowsByID.invalidateAll()
                host.bang(name: "sd.window.destroyed", detail: ["id": Int(wid)])

            default:
                break
            }
        }
    }

    // MARK: - Helpers

    private static func frameDict(_ f: CGRect) -> [String: Int] {
        [
            "x": Int(f.origin.x), "y": Int(f.origin.y),
            "w": Int(f.size.width), "h": Int(f.size.height)
        ]
    }

    // MARK: - TahoeSynth: synthetic moved/resized/minimized via CG poll
    //
    // CGS events 806 (moved), 807 (resized), 815 (deminimized), 816 (minimized)
    // stopped firing on macOS 26 (Tahoe). Hammerspoon side-steps this by
    // installing per-window AXObservers (kAXWindowMovedNotification etc.) — a
    // heavy plumbing extension here. Pragmatic shim: a single 250ms diff
    // against CGWindowListCopyWindowInfo bridges what userland code expects.
    // Latency is acceptable for drag-to-resize / drag-to-reorder (which already
    // batch on mouse-up) and for windowscape's minimize-bang tracking.
    //
    // No-op on prior macOS where the native CGS events still fire — the
    // duplicate bangs are idempotent on the JS side (sd.window.moved consumers
    // dedupe by frame; minimizedIds.add() / delete() are also idempotent).
    fileprivate static var tahoePollPrev: [CGWindowID: (frame: CGRect, onscreen: Bool)] = [:]
    fileprivate static var tahoePollTimer: Timer?

    static func startTahoeSynthPoll() {
        guard tahoePollTimer == nil else { return }
        // Seed prev so the first tick doesn't fire bangs for every existing window.
        tahoePollPrev = snapshotCGWindowState()
        // 100ms tick — fast enough that windowscape's drift watcher (also
        // 100ms-ish) sees a window resize within one frame. CGWindowList
        // enumeration is cheap (~1ms for typical 50-window sessions); the
        // previous 250ms left up to half a second of dead time between
        // "user resized" and "windowscape sees it".
        tahoePollTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { _ in
            tahoePollTick()
        }
    }

    private static func snapshotCGWindowState() -> [CGWindowID: (frame: CGRect, onscreen: Bool)] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) else { return [:] }
        let list = raw as! [[String: Any]]
        var out: [CGWindowID: (frame: CGRect, onscreen: Bool)] = [:]
        for info in list {
            guard let num = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let frame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )
            let onscreen = ((info[kCGWindowIsOnscreen as String] as? Int) ?? 0) != 0
            out[CGWindowID(num)] = (frame: frame, onscreen: onscreen)
        }
        return out
    }

    private static func tahoePollTick() {
        guard let host = AppDelegate.shared?.host else { return }
        let next = snapshotCGWindowState()
        for (wid, cur) in next {
            guard let p = tahoePollPrev[wid] else { continue }
            if p.frame.origin != cur.frame.origin {
                var d: [String: Any] = ["id": Int(wid)]
                d["frame"] = frameDict(cur.frame)
                host.bang(name: "sd.window.moved", detail: d)
            }
            if p.frame.size != cur.frame.size {
                var d: [String: Any] = ["id": Int(wid)]
                d["frame"] = frameDict(cur.frame)
                host.bang(name: "sd.window.resized", detail: d)
            }
            if p.onscreen != cur.onscreen {
                // Gate the minimize bang on AX-confirmed kAXMinimized=true.
                // Without the gate, a tab-merged background window flips
                // onscreen 1→0 every time the user switches Terminal/Safari
                // tabs — the previous foreground tab's CGWindowID goes off-
                // screen but the underlying window wasn't minimized in the
                // AX sense. Hidden-tab CGWindowIDs have no AX element so
                // WindowsByID.isMinimized returns false → bang skipped.
                // Real Cmd+M sets kAXMinimized=true → bang fires.
                let axMin = cur.onscreen ? false : WindowsByID.isMinimized(windowID: wid)
                if let name = tahoeMinimizeBang(
                    prevOnscreen: p.onscreen, curOnscreen: cur.onscreen, axMinimizedNow: axMin
                ) {
                    host.bang(name: name, detail: ["id": Int(wid)])
                }
            }
        }
        tahoePollPrev = next
    }

    /// Pure decision: which minimize-family bang should the Tahoe poll fire
    /// for an `onscreen` transition? Extracted so the tab-switch regression
    /// fix is unit-testable without holding live CGS state.
    ///
    /// - `prev == cur`                      → nil (no transition)
    /// - `cur=true` (off→on)                → `"sd.window.deminimized"` —
    ///   fires unconditionally. Spurious for a background-tab-becoming-
    ///   foreground transition, but downstream snapshot subsystems no-op
    ///   on never-snapshotted ids so the spurious case is benign. A future
    ///   pass can tighten this by tracking prev `axMinimized` per id.
    /// - `cur=false` (on→off) + `axMinNow`  → `"sd.window.minimized"`
    /// - `cur=false` (on→off) + `!axMinNow` → nil — the regression-fix path:
    ///   tab-switching flips onscreen without minimizing, AX confirms the
    ///   window isn't really minimized, so no bang.
    static func tahoeMinimizeBang(prevOnscreen: Bool, curOnscreen: Bool,
                                  axMinimizedNow: Bool) -> String? {
        if prevOnscreen == curOnscreen { return nil }
        if curOnscreen { return "sd.window.deminimized" }
        return axMinimizedNow ? "sd.window.minimized" : nil
    }

    /// Build a sd.window.created detail dict via CGWindowList lookup. One CG
    /// call per creation is fine — events fire on the order of one per app
    /// launch / new-window, not per frame.
    private static func detailForWindow(wid: UInt32) -> [String: Any] {
        var out: [String: Any] = ["id": Int(wid)]
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], CGWindowID(wid)
        ) else { return out }
        let list = raw as! [[String: Any]]
        guard let info = list.first else { return out }

        out["app"]   = (info[kCGWindowOwnerName as String] as? String) ?? ""
        out["pid"]   = (info[kCGWindowOwnerPID  as String] as? Int) ?? 0
        out["title"] = (info[kCGWindowName as String] as? String) ?? ""
        if let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] {
            out["frame"] = [
                "x": Int(bounds["X"] ?? 0),
                "y": Int(bounds["Y"] ?? 0),
                "w": Int(bounds["Width"] ?? 0),
                "h": Int(bounds["Height"] ?? 0)
            ]
        }
        return out
    }
}

// =====================================================================
// MARK: - Per-window snapshot via SkyLight (formerly Sources/DataSources/WindowsSnapshot.swift)
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
// MARK: - Spaces (formerly Sources/DataSources/Spaces.swift)
// =====================================================================

// Per-display Spaces info via SkyLight private SPI. Same family of symbols
// hs.spaces uses (SLSCopyManagedDisplaySpaces, SLSSpaceGetType). Shared
// SkyLight loader lives in Sources/Private/SkyLight.swift; this enum just
// declares the symbol surface this domain needs.
private enum SkyLightSpaces {
    typealias CopyManagedSpacesFn    = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias SpaceGetTypeFn         = @convention(c) (Int32, UInt64) -> Int32
    typealias GetActiveSpaceFn       = @convention(c) (Int32) -> UInt64
    typealias CopySpacesForWindowsFn = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?

    // SLSRegisterConnectionNotifyProc(cid, callback, eventType, context). Used
    // for kCGSEvent space-life notifs that NSWorkspace doesn't surface. Yabai's
    // src/yabai.c is the reference for the exact signature.
    typealias CGSConnectionCallback = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
    typealias RegisterNotifyProcFn  = @convention(c) (Int32, CGSConnectionCallback, UInt32, UnsafeMutableRawPointer?) -> Int32

    static let copyManagedSpaces:    CopyManagedSpacesFn?    = SkyLight.sym("SLSCopyManagedDisplaySpaces")
    static let spaceGetType:         SpaceGetTypeFn?         = SkyLight.sym("SLSSpaceGetType")
    static let getActiveSpace:       GetActiveSpaceFn?       = SkyLight.sym("SLSGetActiveSpace")
    static let copySpacesForWindows: CopySpacesForWindowsFn? = SkyLight.sym("SLSCopySpacesForWindows")
    static let registerNotifyProc:   RegisterNotifyProcFn?   = SkyLight.sym("SLSRegisterConnectionNotifyProc")
}

enum Spaces {
    /// Per-screen spaces info, keyed by NSScreen UUID:
    ///   { uuid: { spaces: [id, ...], active: id|null, isFullscreen: bool } }
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

        var out: [String: Any] = [:]
        for disp in displays {
            var ident = (disp["Display Identifier"] as? String) ?? ""
            if ident == "Main", let main = mainScreenUUID { ident = main }
            let spacesArr = (disp["Spaces"] as? [[String: Any]]) ?? []

            var ids: [UInt64] = []
            for sp in spacesArr {
                if let n = sp["ManagedSpaceID"] as? NSNumber {
                    ids.append(n.uint64Value)
                }
            }
            let activeID = (disp["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber
            let active = activeID?.uint64Value

            // SLSSpaceGetType: 0 = user, 4 = fullscreen/tiled. Mirror hs.spaces.
            var isFullscreen = false
            if let a = active {
                isFullscreen = getType(cid, a) == 4
            }

            out[ident] = [
                "spaces":       ids.map { NSNumber(value: $0) },
                "active":       active.map { NSNumber(value: $0) } as Any? ?? NSNull(),
                "isFullscreen": isFullscreen
            ]
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
}

// CGS event types observed below. Yabai's src/yabai.c is the reference for
// which IDs are live on shipping macOS:
//   1327 — space created
//   1328 — space destroyed
//   1204 — Mission Control entered (proxy for the user-driven space re-order
//          interaction that NSWorkspace's activeSpaceDidChange doesn't fire on
//          when no active-space change happens)
//
// SkyLight exposes no public "remove notify" entry point, so once registered
// the callback lives for the process. We guard registration with a static
// flag and route into the singleton; Token cancel only tears down the
// NSWorkspace / NSApplication observers (the CGS callback no-ops once
// SpacesObserver has no subscribers because fire() iterates an empty subs
// dict).
private let kCGSEventSpaceCreated:        UInt32 = 1327
private let kCGSEventSpaceDestroyed:      UInt32 = 1328
private let kCGSEventMissionControlEnter: UInt32 = 1204

private let spacesCGSCallback: SkyLightSpaces.CGSConnectionCallback = { eventType, _, _, _, _ in
    DispatchQueue.main.async {
        SpacesObserver.shared.fire()
        // 1204 is the only CGS signal for "Mission Control entered" — exit is
        // an AX notification on the Dock, handled in MissionControl.swift.
        if eventType == kCGSEventMissionControlEnter {
            AppDelegate.shared?.host?.bang(name: "sd.missionControl.entered", detail: [:])
        }
    }
}

final class SpacesObserver: RefCountedObserver {
    static let shared = SpacesObserver()
    private override init() { super.init() }

    private static var cgsRegistered = false

    override func install() -> Token {
        // Screen reconfig can add/remove displays, which changes the keys —
        // observe alongside activeSpaceDidChange.
        let ncToken = installNotifications([
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        ])

        if !SpacesObserver.cgsRegistered,
           let reg = SkyLightSpaces.registerNotifyProc {
            let cid = SkyLight.cid
            _ = reg(cid, spacesCGSCallback, kCGSEventSpaceCreated,        nil)
            _ = reg(cid, spacesCGSCallback, kCGSEventSpaceDestroyed,      nil)
            _ = reg(cid, spacesCGSCallback, kCGSEventMissionControlEnter, nil)
            SpacesObserver.cgsRegistered = true
        }

        return ncToken
    }
}

// =====================================================================
// MARK: - Mission Control AX bangs (formerly Sources/DataSources/MissionControl.swift)
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
