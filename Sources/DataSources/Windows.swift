import AppKit
import ApplicationServices
import CoreGraphics

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

    // All on-screen normal windows from CGWindowList.
    static func all() -> [[String: Any]] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) else { return [] }
        let list = raw as! [[String: Any]]
        return list.compactMap { info -> [String: Any]? in
            guard let num   = info[kCGWindowNumber as String]    as? Int,
                  let layer = info[kCGWindowLayer  as String]    as? Int,
                  layer == 0,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  let pid   = info[kCGWindowOwnerPID  as String] as? Int,
                  let bounds = info[kCGWindowBounds as String]   as? [String: CGFloat]
            else { return nil }
            return [
                "id": num,
                "app": owner,
                "pid": pid,
                "title": info[kCGWindowName as String] as? String ?? "",
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
        guard let el = elementFor(windowID: windowID) else { return false }
        var pos = CGPoint(x: x, y: y)
        var sz  = CGSize(width: w, height: h)
        guard let posVal = AXValueCreate(.cgPoint, &pos),
              let szVal  = AXValueCreate(.cgSize,  &sz) else { return false }
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
final class FrontmostWindowObserver: RefCountedObserver {
    static let shared = FrontmostWindowObserver()
    private override init() { super.init() }

    private var currentTokens: [Token] = []
    private var workspaceToken: NSObjectProtocol?

    override func install() -> Token? {
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.installFor(pid: app.processIdentifier)
            // Activation itself counts as a focus change — fire so consumers
            // pick up the new frontmost-app window without waiting for the
            // first within-app AX notification.
            self.fire()
        }
        // Install for current frontmost immediately so subscribers don't have
        // to wait for the next app switch.
        if let app = NSWorkspace.shared.frontmostApplication {
            installFor(pid: app.processIdentifier)
        }
        return Token { [weak self] in
            guard let self = self else { return }
            if let t = self.workspaceToken {
                NSWorkspace.shared.notificationCenter.removeObserver(t)
                self.workspaceToken = nil
            }
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

        let handler: (String) -> Void = { [weak self] _ in self?.fire() }
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
