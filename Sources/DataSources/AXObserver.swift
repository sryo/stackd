import AppKit
import ApplicationServices

/// One AXObserver bound to a single application's pid, plus its CFRunLoopSource.
/// Wraps AXObserverCreate / AXObserverAddNotification with explicit per-
/// notification ref-counting so each registration is paired with a
/// corresponding AXObserverRemoveNotification when the last subscriber for
/// that notification name unsubscribes. Without this pairing, the OS keeps
/// delivering events to an empty subs dict until the AXAppObserver itself
/// drops its last CF reference.
final class AXAppObserver {
    let pid: pid_t
    private let appElement: AXUIElement
    private let observer: AXObserver
    private var subs: [Int: (notif: String, cb: (String) -> Void)] = [:]
    private var nextId: Int = 1
    // Per-notification subscriber counts. Goes 0→1 → AXObserverAddNotification;
    // 1→0 → AXObserverRemoveNotification.
    private var notifCounts: [String: Int] = [:]

    init?(pid: pid_t) {
        self.pid = pid
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.1)
        self.appElement = appEl

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, notif, refcon in
            guard let refcon = refcon else { return }
            let me = Unmanaged<AXAppObserver>.fromOpaque(refcon).takeUnretainedValue()
            let name = notif as String
            // Snapshot before iterating — a callback that synchronously
            // cancels its own Token mutates subs mid-loop otherwise.
            for entry in Array(me.subs.values) where entry.notif == name {
                entry.cb(name)
            }
        }
        let err = AXObserverCreate(pid, callback, &obs)
        guard err == .success, let observer = obs else { return nil }
        self.observer = observer

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    /// Registers `notification` against this app's AXUIElement. The first
    /// subscriber for a given notification calls AXObserverAddNotification;
    /// the Token's cancel decrements the per-notification count and, on the
    /// last unsubscribe, calls AXObserverRemoveNotification — keeping the OS
    /// side in sync with the subscriber set instead of relying on the whole
    /// observer dropping out of scope.
    func add(notification: String, callback: @escaping (String) -> Void) -> Token? {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let currentCount = notifCounts[notification] ?? 0
        if currentCount == 0 {
            let err = AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            // .notificationUnsupported is common for AXTitleChanged on apps
            // without a window — treat as soft-failure, silently no-op.
            guard err == .success || err == .notificationAlreadyRegistered else { return nil }
        }
        notifCounts[notification] = currentCount + 1
        let id = nextId
        nextId += 1
        subs[id] = (notification, callback)
        return Token { [weak self] in
            guard let self = self, self.subs.removeValue(forKey: id) != nil else { return }
            let n = (self.notifCounts[notification] ?? 0) - 1
            if n <= 0 {
                AXObserverRemoveNotification(self.observer, self.appElement, notification as CFString)
                self.notifCounts.removeValue(forKey: notification)
            } else {
                self.notifCounts[notification] = n
            }
        }
    }

    deinit {
        // Remove notifications BEFORE dropping the runloop source so any
        // already-queued callbacks see a still-valid refcon. Then drop the
        // source so the AXObserver's last CF reference is safely retired.
        for notif in notifCounts.keys {
            AXObserverRemoveNotification(observer, appElement, notif as CFString)
        }
        notifCounts.removeAll()
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }
}

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

    private var current: AXAppObserver?
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
            // Explicitly cancel the per-notification Tokens so each
            // AXObserverRemoveNotification fires while `current` is still
            // alive — matching the Token contract instead of relying on
            // deinit timing.
            for t in self.currentTokens { t.cancel() }
            self.currentTokens.removeAll()
            self.current = nil
        }
    }

    private func installFor(pid: pid_t) {
        // Cancel the previous app's Tokens before letting `current` drop —
        // that pairs each AXObserverAddNotification with an explicit
        // AXObserverRemoveNotification (instead of waiting for deinit).
        for t in currentTokens { t.cancel() }
        currentTokens.removeAll()
        current = nil

        guard let obs = AXAppObserver(pid: pid) else { return }
        let handler: (String) -> Void = { [weak self] _ in self?.fire() }
        for notif in [
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXTitleChangedNotification
        ] {
            if let t = obs.add(notification: notif as String, callback: handler) {
                currentTokens.append(t)
            }
        }
        current = obs
    }
}
