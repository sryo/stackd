import AppKit
import ApplicationServices

/// One AXObserver bound to a single application's pid, plus its CFRunLoopSource.
/// Wraps AXObserverCreate / AXObserverAddNotification so the lifecycle is
/// cleanly tied to this object's lifetime — deinit removes the source and
/// drops the observer (Apple's API has no explicit destroy; releasing the
/// last CF reference is the teardown).
final class AXAppObserver {
    let pid: pid_t
    private let appElement: AXUIElement
    private let observer: AXObserver
    private var subs: [Int: (String) -> Void] = [:]   // notification name -> cb
    private var nextId: Int = 1
    private var installedNotifications: Set<String> = []

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
            for cb in me.subs.values { cb(name) }
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

    /// Registers `notification` against this app's AXUIElement; the callback
    /// fires with the notification name so a single observer can multiplex
    /// across kAXFocusedWindowChangedNotification, kAXTitleChangedNotification, etc.
    /// Returns nil if AX denied or the notification isn't applicable to this app.
    func add(notification: String, callback: @escaping (String) -> Void) -> Token? {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if !installedNotifications.contains(notification) {
            let err = AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            // .notificationUnsupported is common for AXTitleChanged on apps
            // without a window — treat as soft-failure, silently no-op.
            guard err == .success || err == .notificationAlreadyRegistered else { return nil }
            installedNotifications.insert(notification)
        }
        let id = nextId
        nextId += 1
        subs[id] = { name in if name == notification { callback(name) } }
        return Token { [weak self] in self?.subs.removeValue(forKey: id) }
    }

    deinit {
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        // AXObserver itself is released when this stored reference drops.
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

    override func install() -> Token {
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
            self.currentTokens.removeAll()
            self.current = nil
        }
    }

    private func installFor(pid: pid_t) {
        // Drop tokens first so they release notification handlers BEFORE the
        // observer's CFRunLoopSource is removed (deinit on `current`).
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
