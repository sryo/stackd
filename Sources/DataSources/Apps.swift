import AppKit

// Running apps as a signal + the four imperative verbs every launcher /
// dock / kill-switch eventually needs. Apps without a bundle id (rare but
// real — some kernel-side helpers, some old apps) are filtered out — there's
// no way to launch / focus them by ID anyway.

enum Apps {
    static func running() -> [[String: Any]] {
        NSWorkspace.shared.runningApplications.compactMap { app -> [String: Any]? in
            guard let bundleId = app.bundleIdentifier else { return nil }
            // activationPolicy mirrors NSApplication.ActivationPolicy:
            //   "regular"    — normal Dock-visible UI app (Lua's app:kind() == 1)
            //   "accessory"  — LSUIElement / background-with-UI (status item, etc.)
            //   "prohibited" — never appears in UI (XPC helpers, etc.)
            // Lets consumers filter helper processes out the same way Hammerspoon
            // does. Used by AppTimeout to skip background helpers.
            let policy: String = {
                switch app.activationPolicy {
                case .regular:    return "regular"
                case .accessory:  return "accessory"
                case .prohibited: return "prohibited"
                @unknown default: return "regular"
                }
            }()
            var entry: [String: Any] = [
                "pid":              Int(app.processIdentifier),
                "bundleId":         bundleId,
                "name":             app.localizedName ?? "",
                "active":           app.isActive,
                "hidden":           app.isHidden,
                "activationPolicy": policy
            ]
            if let date = app.launchDate {
                entry["launchedAt"] = date.timeIntervalSince1970
            }
            return entry
        }
    }

    @discardableResult
    static func launch(bundleId: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        return true
    }

    /// Focus the app if running; otherwise launch it. Matches user intent
    /// for both launcher hotkeys ("open Safari") and "go to my Calendar".
    @discardableResult
    static func focus(bundleId: String) -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            return app.activate(options: [.activateAllWindows])
        }
        return launch(bundleId: bundleId)
    }

    @discardableResult
    static func kill(bundleId: String, force: Bool = false) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return false }
        return force ? app.forceTerminate() : app.terminate()
    }

    @discardableResult
    static func hide(bundleId: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return false }
        return app.hide()
    }
}

final class AppsObserver {
    static let shared = AppsObserver()
    private var subs: [() -> Void] = []

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        for name in names {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.fire()
            }
        }
    }

    func subscribe(_ cb: @escaping () -> Void) { subs.append(cb) }
    func unsubscribeAll() { subs.removeAll() }
    private func fire() { for cb in subs { cb() } }
}
