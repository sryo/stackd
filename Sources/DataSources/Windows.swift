import AppKit
import ApplicationServices
import CoreGraphics

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
    static func all() -> [[String: Any]] {
        // SLSCopyWindowsWithOptionsAndTags is the yabai-style "authoritative"
        // path but crashes inside SkyLight on macOS 26 (Tahoe) — repro: any
        // stack with `windows` permission segfaults at startWorkspace's
        // first push. Until the SPI signature is re-verified on Tahoe we
        // route through the public CGWindowListCopyWindowInfo only.
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) else { return [] }
        return decode(raw as! [[String: Any]])
    }

    private static func decode(_ list: [[String: Any]]) -> [[String: Any]] {
        list.compactMap { info -> [String: Any]? in
            guard let num   = info[kCGWindowNumber as String]    as? Int,
                  let layer = info[kCGWindowLayer  as String]    as? Int,
                  layer == 0,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  let pid   = info[kCGWindowOwnerPID  as String] as? Int,
                  let bounds = info[kCGWindowBounds as String]   as? [String: CGFloat]
            else { return nil }
            let onscreen = (info[kCGWindowIsOnscreen as String] as? Int) ?? 0
            return [
                "id": num,
                "app": owner,
                "pid": pid,
                "title": info[kCGWindowName as String] as? String ?? "",
                "onscreen": onscreen != 0,
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
        axCache[pid] = nil
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
        axCache[pid] = map
        cacheLock.unlock()
        return map[windowID]
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
        var toolbarPresent = false
        var childrenRef: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children where axStringAttribute(child, kAXRoleAttribute) == "AXToolbar" {
                toolbarPresent = true
                break
            }
        }
        return [
            "toolbarPresent": toolbarPresent,
            "role":           role    as Any? ?? NSNull(),
            "subrole":        subrole as Any? ?? NSNull()
        ]
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

    /// Per-event-type callbacks, set once at startup by Bridge. The observer
    /// is process-global; only one stack-driving consumer (Bridge) sets these.
    /// Each fires in addition to (not instead of) the union `fire()` so the
    /// legacy `sd.windows.focused` channel keeps working.
    var onAppActivated:  (() -> Void)?
    var onFocusedChanged: (() -> Void)?
    var onTitleChanged:  (() -> Void)?

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
                 self.onAppActivated?()
                 // Focus changes with the app switch — pump the focused-window
                 // channel too so stacks that only listen to focusedChanged
                 // don't miss the cross-app transition.
                 self.onFocusedChanged?()
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
                self.onFocusedChanged?()
            case kAXTitleChangedNotification:
                self.onTitleChanged?()
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
