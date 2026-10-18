import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

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

// SLSTransaction* — atomic batch of window geometry/order mutations committed
// to WindowServer in one round-trip. Consumed by the overlay tick's
// reshape+order (Overlay, OverlayHandle). sd.windows.batch does not use it:
// the batch path queues full frames and applies them all-AX at commit — see
// the batchSink doc comment in WindowsByID for the channel-split race that
// rules out the SLS-position/AX-size split.
//
// Lives here (not in Sources/Private/SkyLight.swift) because the primary
// domain is windows. Mirrors Hammerspoon's per-extension SPI ownership.
//
// Signatures verified against yabai/src/misc/extern.h and JankyBorders/
// src/misc/extern.h (SLSTransactionMoveWindowWithGroup: (CFTypeRef, uint32_t,
// CGPoint), point = absolute CGS top-left global origin — same space as
// AX/CG, no flip).
enum WindowTransaction {
    typealias CreateFn          = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    // SLSTransactionCommit returns nothing: the register it leaves behind is
    // not a status code, so a commit is never judged by its result.
    typealias CommitFn          = @convention(c) (CFTypeRef, Int32) -> Void
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

// Window primitives, by source-of-truth:
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
//   WindowAXRead             — several attributes of one window in one AX
//                              round trip.
//
//   WindowsByID              — per-window actions targeting a specific
//                              CGWindowID via the AXShim lookup; per-pid
//                              ID→AX cache so consecutive calls skip the
//                              app-windows traversal.
//
// The rest of the window layer lives beside this file: lifecycle events in
// WindowsAXObserver.swift (primary), WindowEvents.swift (CGS) and
// WindowsLifecycle.swift (the safety poll and create fan-out); the
// addressability verdicts behind Windows.all() in
// WindowsAddressability.swift; frontmost focus in WindowsFocus.swift;
// animated writes in WindowMotion.swift.

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
        let read = WindowAXRead(win, WindowAXRead.titleAndFrame)
        let frame = read.frameOrZero

        // Recover CGWindowID via the private SPI so per-window-id consumers
        // (sd.windows.byId, tiler-style stacks) can target this exact window.
        var winId: CGWindowID = 0
        var id: CGWindowID? = nil
        if let getWindow = AXShim.getWindow, getWindow(win, &winId) == .success {
            id = winId
        }
        return FocusedWindowRead(title: read.string(kAXTitleAttribute) ?? "",
                                 origin: frame.origin, size: frame.size, id: id)
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

    /// Own-pid cache — stackd's own panels show up in CGWindowList alongside
    /// real user windows and would pollute every consumer that iterates them
    /// (windowscape tiling, framemaster border-drawing, custom switchers,
    /// etc.), so Windows.all() leaves them out.
    private static let ownPid: Int = Int(ProcessInfo.processInfo.processIdentifier)

    /// Window-server levels an app's own document windows live at: normal,
    /// floating ("keep on top" windows, e.g. Claude's main window when
    /// pinned) and modal panel — yabai's standard-level set. Menus, status
    /// items, popups and screen-saver-level overlays stay out.
    private static let appWindowLevels: Set<Int> = [
        Int(CGWindowLevelForKey(.normalWindow)),
        Int(CGWindowLevelForKey(.floatingWindow)),
        Int(CGWindowLevelForKey(.modalPanelWindow)),
    ]

    static func isAppWindowLevel(_ layer: Int) -> Bool {
        appWindowLevels.contains(layer)
    }

    /// The app windows WindowServer knows of, including minimized, other-space
    /// and offscreen ones; each row carries `onscreen` so consumers that want
    /// only visible windows can filter. Standard windows only, stackd's own
    /// panels excluded.
    static func all() -> [[String: Any]] {
        // SLSCopyWindowsWithOptionsAndTags is the yabai-style "authoritative"
        // path but crashes inside SkyLight on macOS 26 (Tahoe) — repro: any
        // stack with `windows` permission segfaults at startWorkspace's
        // first push. Until the SPI signature is re-verified on Tahoe we
        // route through the public CGWindowListCopyWindowInfo only.
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        guard WindowDebug.enabled else { return decode(raw) }
        let began = CFAbsoluteTimeGetCurrent()
        _ = WindowAddressabilityCache.takeLiveProbeCount()
        let out = decode(raw)
        let ms = Int((CFAbsoluteTimeGetCurrent() - began) * 1000)
        if ms >= 10 {
            WindowDebug.log("windows.all: \(ms)ms, \(WindowAddressabilityCache.takeLiveProbeCount()) live AX probes")
        }
        return out
    }

    /// CGWindowList rows → Windows.all() rows. `probe` gives each window's
    /// AX verdict (the addressability cache in production).
    static func decode(
        _ list: [[String: Any]],
        probe: (pid_t, CGWindowID) -> WindowAddressabilityCache.Probe = {
            WindowAddressabilityCache.probe(pid: $0, windowID: $1)
        }
    ) -> [[String: Any]] {
        var bundleIds: [Int: String?] = [:]
        func bundleId(_ pid: Int) -> String? {
            if let hit = bundleIds[pid] { return hit }
            let bid = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
            bundleIds[pid] = bid
            return bid
        }
        return list.compactMap { info -> [String: Any]? in
            guard let num   = info[kCGWindowNumber as String]    as? Int,
                  let layer = info[kCGWindowLayer  as String]    as? Int,
                  Windows.isAppWindowLevel(layer),
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  let pid   = info[kCGWindowOwnerPID  as String] as? Int,
                  let bounds = info[kCGWindowBounds as String]   as? [String: CGFloat]
            else { return nil }
            if pid == ownPid { return nil }
            let onscreen = (info[kCGWindowIsOnscreen as String] as? Int) ?? 0
            // Enrich with AX-derived fields the stack would otherwise have
            // to probe per-pass:
            //   addressable: AX can resolve an AXUIElement for this id
            //   isStandard:  AXSubrole == AXStandardWindow (filters out
            //                Inspector / preferences / helper windows)
            // Both cached per (pid, id) with a TTL so a 50-window
            // CGWindowList push doesn't fan out 50+50 AX RPCs every time.
            let verdict = probe(pid_t(pid), CGWindowID(num))
            // Skip non-standard windows (Notification Center banners,
            // Spotlight overlays, popovers, sheets, system HUDs). Matches
            // Hammerspoon's `hs.window.allWindows()` and yabai's
            // `window_manager_find_windows_on_storage`.
            if !verdict.isStandard { return nil }
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
                "addressable": verdict.addressable,
                "isStandard":  verdict.isStandard,
                "isMinimized": verdict.isMinimized,
                "level": layer,
                "frame": [
                    "x": originX,
                    "y": originY,
                    "w": Int(bounds["Width"] ?? 0),
                    "h": Int(bounds["Height"] ?? 0)
                ]
            ]
            if let bid = bundleId(pid) { out["bundleId"] = bid }
            if let d = Display.forPoint(CGPoint(x: originX, y: originY)) {
                out["display"] = d
            }
            if let t = verdict.traits { out.merge(t.fields) { $1 } }
            return out
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
            log("_AXUIElementGetWindow unavailable")
            return nil
        }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()
}

// MARK: - WindowAXRead: several window attributes in one AX round trip

/// A window's attributes read with one AXUIElementCopyMultipleAttributeValues
/// call, so N attributes cost the app one IPC instead of N. The app answers
/// each attribute independently: a slot it could not read holds an AXValue
/// of type .axError (or kCFNull for an attribute with no value) in place of
/// the value, and decodes to `.failure` with that error. A call that fails
/// outright (dead element, messaging timeout) fails every slot with the
/// call's error.
struct WindowAXRead {
    enum Slot {
        case value(AnyObject)
        case failure(AXError)
    }

    private let slots: [String: Slot]

    static let positionAndSize = [kAXPositionAttribute, kAXSizeAttribute]
    static let titleAndFrame = [kAXTitleAttribute] + positionAndSize

    /// The element's frame in one round trip; nil unless position and size
    /// both read. Thread-agnostic.
    static func frame(of el: AXUIElement) -> CGRect? {
        WindowAXRead(el, positionAndSize).frame
    }

    /// Blocks for up to the element's AX messaging timeout. Thread-agnostic.
    init(_ el: AXUIElement, _ attributes: [String]) {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            el, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        self.init(attributes: attributes, values: err == .success ? values as? [AnyObject] : nil, callError: err)
    }

    /// Decodes one call's result: `values` is the returned array (nil when
    /// the call failed), `callError` what the call returned.
    init(attributes: [String], values: [AnyObject]?, callError: AXError) {
        var slots: [String: Slot] = [:]
        for (i, name) in attributes.enumerated() {
            guard let values = values else {
                slots[name] = .failure(callError == .success ? .failure : callError)
                continue
            }
            slots[name] = i < values.count ? Self.decode(values[i]) : .failure(.noValue)
        }
        self.slots = slots
    }

    private static func decode(_ raw: AnyObject) -> Slot {
        if raw === kCFNull { return .failure(.noValue) }
        if CFGetTypeID(raw) == AXValueGetTypeID() {
            let v = raw as! AXValue
            if AXValueGetType(v) == .axError {
                var code: Int32 = AXError.failure.rawValue
                _ = AXValueGetValue(v, .axError, &code)
                return .failure(AXError(rawValue: code) ?? .failure)
            }
        }
        return .value(raw)
    }

    /// An attribute that was not asked for reads as a failure.
    func slot(_ attribute: String) -> Slot { slots[attribute] ?? .failure(.noValue) }

    func value(_ attribute: String) -> AnyObject? {
        if case .value(let v) = slot(attribute) { return v }
        return nil
    }

    /// `.success` for a slot that holds a value.
    func error(_ attribute: String) -> AXError {
        if case .failure(let e) = slot(attribute) { return e }
        return .success
    }

    func string(_ attribute: String) -> String? { value(attribute) as? String }
    func bool(_ attribute: String) -> Bool? { value(attribute) as? Bool }
    func point(_ attribute: String) -> CGPoint? { AX.point(from: value(attribute)) }
    func size(_ attribute: String) -> CGSize? { AX.size(from: value(attribute)) }
    func element(_ attribute: String) -> AXUIElement? { AX.element(from: value(attribute)) }

    /// kAXPosition + kAXSize as one rect; nil unless both read.
    var frame: CGRect? {
        guard let origin = point(kAXPositionAttribute), let size = size(kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// kAXPosition + kAXSize with an unreadable half left at zero, the shape
    /// the frame readers report for a window whose element resolved.
    var frameOrZero: CGRect {
        CGRect(origin: point(kAXPositionAttribute) ?? .zero, size: size(kAXSizeAttribute) ?? .zero)
    }
}

/// A window's AXSubrole as one sample: AXStandardWindow, some other subrole,
/// or no readable subrole. A read that errored (app still building the
/// window, AX timeout under load) stays `.unknown`, apart from
/// `.nonStandard`, so a gate can recheck it instead of dropping the window.
/// `.nonStandard` is not final either: mid minimize/deminimize a real window
/// reads AXDialog.
enum WindowSubroleVerdict: Equatable {
    case standard, nonStandard, unknown

    init(_ slot: WindowAXRead.Slot) {
        guard case .value(let v) = slot else { self = .unknown; return }
        self.init(subrole: v as? String)
    }

    /// nil is an unreadable subrole.
    init(subrole: String?) {
        guard let s = subrole else { self = .unknown; return }
        self = WindowsByID.isStandardSubrole(s) ? .standard : .nonStandard
    }
}

// MARK: - WindowsByID: per-window actions targeting a CGWindowID

/// Elements per app window plus each window's owning pid, kept in step so
/// a window's owner is one lookup. A walk of an app's windows merges in:
/// windows it leaves out keep their elements, and a window id another app's
/// walk lists moves to that app. Generic over the element so the
/// bookkeeping is testable without AX; the caller locks.
struct WindowElementIndex<Element> {
    private var byPid: [pid_t: [CGWindowID: Element]] = [:]
    private var owner: [CGWindowID: pid_t] = [:]

    /// Apps holding at least one window, ascending.
    var pids: [pid_t] { byPid.keys.sorted() }

    func element(windowID: CGWindowID, pid: pid_t) -> Element? { byPid[pid]?[windowID] }

    func pid(for windowID: CGWindowID) -> pid_t? { owner[windowID] }

    mutating func merge(pid: pid_t, _ walk: [CGWindowID: Element]) {
        for (wid, el) in walk {
            if let previous = owner[wid], previous != pid { remove(pid: previous, windowID: wid) }
            byPid[pid, default: [:]][wid] = el
            owner[wid] = pid
        }
    }

    mutating func remove(pid: pid_t, windowID: CGWindowID) {
        guard byPid[pid]?.removeValue(forKey: windowID) != nil else { return }
        if owner[windowID] == pid { owner[windowID] = nil }
        if byPid[pid]?.isEmpty == true { byPid[pid] = nil }
    }

    mutating func remove(pid: pid_t) {
        guard let windows = byPid.removeValue(forKey: pid) else { return }
        for wid in windows.keys where owner[wid] == pid { owner[wid] = nil }
    }

    mutating func removeAll() {
        byPid.removeAll()
        owner.removeAll()
    }
}

/// Pure resolution order for a window's owning pid: the AX element cache's
/// owner map first, then `query`, the single-window CGWindowList fallback.
enum WindowOwnerLookup {
    static func pid<Element>(for windowID: CGWindowID,
                             cached: WindowElementIndex<Element>,
                             query: (CGWindowID) -> pid_t?) -> pid_t? {
        cached.pid(for: windowID) ?? query(windowID)
    }
}

/// When a failed attribute read on a cached element means "re-resolve the
/// element and read again" rather than a real answer about the window.
enum StaleElementRetry {
    static func shouldReResolve(readError: AXError, attempt: Int) -> Bool {
        attempt == 0 && (readError == .invalidUIElement || readError == .cannotComplete)
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
    // made begin fail outright on some daemon states. WindowTransaction
    // serves the overlay tick's reshape+order, not the batch.
    static var batchSink: ((CGWindowID, CGRect) -> Void)?

    // Pending frames for the open batch. Last-write-wins per window id,
    // first-seen order preserved. Pure struct so the bookkeeping is testable
    // without any window server.
    struct BatchFrameLedger {
        private var frames = LatestWinsQueue<CGWindowID, CGRect>()
        mutating func record(id: CGWindowID, frame: CGRect) {
            frames.offer(id, frame) { _, newer in newer }
        }
        mutating func drain() -> [(id: CGWindowID, frame: CGRect)] {
            frames.take().map { (id: $0.key, frame: $0.value) }
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

    // pid → (CGWindowID → AXUIElement), with each window's owner. Repopulated
    // lazily on lookup miss.
    private static var axCache = WindowElementIndex<AXUIElement>()
    private static let cacheLock = NSLock()

    static func invalidateCache(pid: pid_t, windowID: CGWindowID) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        axCache.remove(pid: pid, windowID: windowID)
    }

    /// Every element held for `pid`'s windows (the app quit).
    static func invalidateCache(pid: pid_t) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        axCache.remove(pid: pid)
    }

    static func invalidateAll() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        axCache.removeAll()
    }

    /// Resolves a CGWindowID → AXUIElement by walking the app's window list.
    /// Uses a per-pid cache to amortize the AX traversal across calls.
    static func elementFor(windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        cacheLock.lock()
        if let cached = axCache.element(windowID: windowID, pid: pid) {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        return freshElement(windowID: windowID, pid: pid)
    }

    /// The window's element as AX vends it right now, never a cached one:
    /// walks the app's window list and merges every element it finds into
    /// the cache. nil when the walk doesn't list the window (the cache keeps
    /// whatever it held for it).
    static func freshElement(windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        guard let getWindow = AXShim.getWindow else { return nil }
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
        axCache.merge(pid: pid, map)
        cacheLock.unlock()
        return map[windowID]
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
        let cached = axCache
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
        let frame = CGRect(x: x, y: y, width: w, height: h)
        let ok = writeFrameAX(element: el, frame: frame)
        if ok { FrameLedger.shared.recordWrite(windowID: windowID, frame: frame) }
        return ok
    }

    /// The size→position→size write, synchronous on the caller's thread, so
    /// an instant setFrame or a batch commit has landed when it returns.
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
        liftIfOverhanging(element: el, target: frame)
        _ = AXUIElementSetAttributeValue(el, kAXSizeAttribute     as CFString, szVal)
        let pOK = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posVal)
        let sOK = AXUIElementSetAttributeValue(el, kAXSizeAttribute     as CFString, szVal)
        keepInsideIfHeldLarger(element: el, target: frame)
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

    /// The lift step of FrameWriteSteps: a window overhanging the display
    /// its target is on moves fully inside at its current size before the
    /// size writes, which AppKit otherwise refuses. Thread-agnostic.
    static func liftIfOverhanging(element el: AXUIElement, target: CGRect) {
        guard let display = displayBounds(for: target),
              let current = WindowAXRead.frame(of: el),
              case .position(var lift)? = FrameWriteSteps.plan(current: current, target: target, display: display).first,
              let liftVal = AXValueCreate(.cgPoint, &lift) else { return }
        _ = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, liftVal)
    }

    /// The keepInside step of FrameWriteSteps: a window the app held larger
    /// than the target moves back onto the target's display. Thread-agnostic.
    static func keepInsideIfHeldLarger(element el: AXUIElement, target: CGRect) {
        guard let landed = WindowAXRead.frame(of: el),
              var origin = FrameWriteSteps.keepInside(target: target, landed: landed,
                                                      display: displayBounds(for: target)),
              let val = AXValueCreate(.cgPoint, &origin) else { return }
        _ = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, val)
    }

    private static func displayBounds(for target: CGRect) -> CGRect? {
        let displays = MotionClock.activeDisplays()
        guard let id = MotionClock.display(for: target, displays: displays) else { return nil }
        return displays.first(where: { $0.id == id })?.bounds
    }

    /// The motion engine's settle frame: the lift step, two setters in
    /// `order`, then a size read-back, and a third size set (with the
    /// keep-inside step) only when the app reports a size other than the
    /// one written.
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
        liftIfOverhanging(element: el, target: frame)
        switch order {
        case .positionThenSize:
            pOK = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posVal)
            sOK = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, szVal)
        case .sizeThenPosition:
            sOK = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, szVal)
            pOK = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posVal)
        }
        let readBack = AX.size(of: el, kAXSizeAttribute)
        if FrameWriteOrder.needsSizeReassert(target: frame, readBack: readBack) {
            sOK = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, szVal)
            keepInsideIfHeldLarger(element: el, target: frame)
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
    /// An unreadable half reads as zero once the element resolved.
    static func frame(windowID: CGWindowID) -> CGRect? {
        guard let el = elementFor(windowID: windowID) else { return nil }
        return WindowAXRead(el, WindowAXRead.positionAndSize).frameOrZero
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
    ///   - `radii`:          the window server's own corner radii, four
    ///                       values in points (0 = square); nil before
    ///                       macOS 26 or for an unknown id
    ///
    /// `radii` is the exact shape the window is drawn with, read from the
    /// window server rather than AX, so a busy app can't time it out. The AX
    /// keys stay for the standard-window gate and as a fallback when `radii`
    /// is nil.
    ///
    /// AX timeout capped at 100ms so one unresponsive app can't stall a
    /// per-tick overlay loop. Returns nil keys (or empty dict) when the AX
    /// query fails — the daemon never invents data.
    static func cornerHints(windowID: CGWindowID) -> [String: Any] {
        let radii: Any = Overlay.cornerRadii(of: windowID) ?? NSNull()
        guard let el = elementFor(windowID: windowID) else {
            return ["toolbarPresent": false, "role": NSNull(), "subrole": NSNull(), "radii": radii]
        }
        AXUIElementSetMessagingTimeout(el, 0.1)
        let read = WindowAXRead(el, [kAXRoleAttribute, kAXSubroleAttribute])
        return cornerHints(el, role: read.string(kAXRoleAttribute), subrole: read.string(kAXSubroleAttribute),
                           radii: radii)
    }

    private static func cornerHints(_ el: AXUIElement, role: String?, subrole: String?, radii: Any) -> [String: Any] {
        [
            "toolbarPresent": elementHasToolbar(el),
            "role":           role    as Any? ?? NSNull(),
            "subrole":        subrole as Any? ?? NSNull(),
            "radii":          radii
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
    /// isStandard + cornerHints + frame + title — was 4 RPCs, now 1). The
    /// window's own attributes arrive in one multi-attribute read.
    ///
    /// Returns nil when the window is unaddressable. Each field is best-
    /// effort: a missing property is null/false, not a hard failure.
    static func info(windowID: CGWindowID) -> [String: Any]? {
        guard let el = elementFor(windowID: windowID) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.1)
        let read = WindowAXRead(el, infoAttributes)
        let f = read.frameOrZero
        let frame: [String: Int] = [
            "x": Int(f.origin.x), "y": Int(f.origin.y), "w": Int(f.size.width), "h": Int(f.size.height)
        ]
        let role = read.string(kAXRoleAttribute)
        let subrole = read.string(kAXSubroleAttribute)
        let radii: Any = Overlay.cornerRadii(of: windowID) ?? NSNull()
        // Strings: nil → NSNull so JSON.stringify yields null.
        return [
            "frame":        frame,
            "title":        read.string(kAXTitleAttribute) as Any? ?? NSNull(),
            "role":         role as Any? ?? NSNull(),
            "subrole":      subrole as Any? ?? NSNull(),
            "isMinimized":  read.bool(kAXMinimizedAttribute) ?? false,
            "isFullscreen": read.bool(fullScreenAttribute) ?? false,
            "isMain":       read.bool(kAXMainAttribute) ?? false,
            "isStandard":   isStandardSubrole(subrole),
            // Any value under AXToolbar, unlike cornerHints' child walk.
            "hasToolbar":   read.value(toolbarAttribute) != nil,
            "cornerHints":  cornerHints(el, role: role, subrole: subrole, radii: radii)
        ].merging(WindowTraits.read(el).fields) { $1 }
    }

    private static let fullScreenAttribute = "AXFullScreen"
    private static let toolbarAttribute = "AXToolbar"
    private static let infoAttributes = [
        kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute, kAXRoleAttribute, kAXSubroleAttribute,
        kAXMinimizedAttribute, fullScreenAttribute, kAXMainAttribute, toolbarAttribute,
    ]

    /// Traffic-light button frames in the same global, top-left-origin coord
    /// space as `frame()`. Returns nil when the window is unaddressable; each
    /// of `close` / `zoom` / `minimize` is `{x,y,w,h}` or NSNull when the
    /// button doesn't exist on this window (some panels and helper windows
    /// lack one or more dots). Used by stacks that want to intercept clicks
    /// on the native dots (e.g. windowscape routes the yellow dot to its
    /// snapshot subsystem instead of the OS genie).
    ///
    /// One round trip resolves the three buttons, then one per button reads
    /// its frame. AX timeout 100ms — same gate as `cornerHints` / `info`.
    static func buttonFrames(windowID: CGWindowID) -> [String: Any]? {
        guard let el = elementFor(windowID: windowID) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.1)
        let buttons = WindowAXRead(el, buttonAttributes.map(\.attribute))
        var out: [String: Any] = [:]
        for (key, attribute) in buttonAttributes {
            let rect = buttons.element(attribute).flatMap { button -> [String: Int]? in
                let f = WindowAXRead(button, WindowAXRead.positionAndSize).frameOrZero
                guard f.size.width > 0, f.size.height > 0 else { return nil }
                return ["x": Int(f.origin.x), "y": Int(f.origin.y), "w": Int(f.size.width), "h": Int(f.size.height)]
            }
            out[key] = rect.map { $0 as Any } ?? NSNull()
        }
        return out
    }

    private static let buttonAttributes: [(key: String, attribute: String)] = [
        ("close", "AXCloseButton"), ("zoom", "AXZoomButton"), ("minimize", "AXMinimizeButton"),
    ]

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
