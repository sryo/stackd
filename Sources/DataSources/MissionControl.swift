import AppKit
import ApplicationServices

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
