import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

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
/// Layout (0xf8 declared bytes in a zero-padded 0x100 buffer, all other bytes
/// zero; the record encoder reads past the declared length):
///   0x04       declared record length (0xf8)
///   0x08       event type: 0x01 press, 0x02 release
///   0x20..0x2f location, filled with 0xff
///   0x3a       0x10, the make-key-window flag
///   0x3c..0x3f target window id, little-endian
enum KeyWindowEventRecord {
    static let length = 0xF8
    static let bufferSize = 0x100

    static func pressAndRelease(windowID: CGWindowID) -> [[UInt8]] {
        [record(windowID: windowID, type: 0x01), record(windowID: windowID, type: 0x02)]
    }

    private static func record(windowID: CGWindowID, type: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: bufferSize)
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

// MARK: - FrontmostWindowObserver: event-driven focus/title changes

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
    private var reads = FocusedReadSchedule()
    private var installRetry = AXInstallRetry()

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
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            installFor(pid: pid)
        }
        return Token { [weak self] in
            ncToken.cancel()
            guard let self = self else { return }
            self.reads.reset()
            self.installRetry.reset(to: nil)
            // Cancel the pool subscriptions so the AXObserverPool tears down
            // its per-pid AXAppObserver when this was the last subscriber —
            // matching the Token contract instead of waiting on deinit.
            for t in self.currentTokens { t.cancel() }
            self.currentTokens.removeAll()
        }
    }

    /// The app switch (didActivateApplication). Main thread.
    private func activate(pid: pid_t) {
        installFor(pid: pid)
        fireAppActivated()
        // The focused-window side of the switch (focusedChanged and the
        // union channel) waits for the confirmed read of this pid: a
        // main-thread read here would block on the app.
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

    private static let observedNotifications = [
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXTitleChangedNotification
    ]

    private func installFor(pid: pid_t) {
        // Drop the previous app's pool subscriptions before subscribing to the
        // new pid so AXObserverPool can retire the old AXAppObserver if no
        // other consumers are using it.
        for t in currentTokens { t.cancel() }
        currentTokens.removeAll()
        installRetry.reset(to: pid)
        install(pid: pid, notifications: Self.observedNotifications, retrying: false)
    }

    /// Subscribes `pid` to `notifications`; the ones the app refuses (a
    /// just-launched app refuses all of them, see AXInstallRetry) are
    /// retried on the backoff while `pid` stays frontmost.
    private func install(pid: pid_t, notifications: [String], retrying: Bool) {
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
        // Each refusal can hold main for the app's 0.1 s AX messaging
        // timeout, and an app that refuses one notification refuses the
        // rest, so the first refusal defers the remainder to the retry.
        var refused: [String] = []
        for (i, notif) in notifications.enumerated() {
            if let t = AXObserverPool.observe(pid: pid, notification: notif, callback: handler) {
                currentTokens.append(t)
            } else {
                refused = Array(notifications[i...])
                break
            }
        }
        // The app answers now, but its window may have taken focus while it
        // was refusing: that posted nothing we could hear, and the
        // activation's read may already have delivered "no window".
        let focusNotif = kAXFocusedWindowChangedNotification
        if retrying && notifications.contains(focusNotif) && !refused.contains(focusNotif) {
            requestFocusedRead(pid: pid)
        }
        // Plain log, not WindowDebug: these fire once per app launch, and a
        // frontmost app nobody observes is otherwise invisible.
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        if retrying && refused.isEmpty {
            log("frontmost: pid=\(pid) (\(name)) AX observers installed on retry")
        }
        guard !refused.isEmpty else { return }
        guard let next = installRetry.failed(pid: pid) else {
            if retrying {
                log("frontmost: pid=\(pid) (\(name)) still refuses \(refused) after all retries; its focus changes go unseen until the next activation")
            }
            return
        }
        if !retrying {
            log("frontmost: pid=\(pid) (\(name)) refused \(refused) at activation; retrying")
        }
        WindowDebug.log("frontmost: pid=\(pid) refused \(refused), retry in \(next.after)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + next.after) { [weak self] in
            guard let self = self, self.isActive,
                  self.installRetry.isDue(pid: pid, token: next.token) else { return }
            self.install(pid: pid, notifications: refused, retrying: true)
        }
    }
}
