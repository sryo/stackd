import AppKit
import Foundation

// System sleep + screen-lock state. Pure observer — no assertion API yet
// (IOPMAssertionCreateWithName would be the v2 addition for "prevent sleep
// while my recording stack is open" use cases).
//
// Three consumers from the audit:
//  - apptimeout: don't accumulate windowless time while the screen is locked
//  - timetrail: stop drawing while screen is off
//  - undoclose: ignore destroyed bangs during logout / screen-lock burst
enum Caffeinate {
    /// Snapshot used by Bridge to push the initial signal value.
    /// `sleeping` flips true between willSleep and didWake. `locked` flips
    /// true between screenIsLocked and screenIsUnlocked. CGSSession lets us
    /// resolve `locked` at startup so a stack that loads while the screen is
    /// already locked sees the correct initial state.
    static func snapshot() -> [String: Any] {
        return [
            "sleeping": CaffeinateObserver.shared.sleepingFlag,
            "locked":   CaffeinateObserver.shared.lockedFlag
        ]
    }

    /// Reads the current CGSession lock state (true if screen is locked).
    /// Used once at observer install to seed `lockedFlag`.
    fileprivate static func currentlyLocked() -> Bool {
        // Auto-bridges to CFDictionary on modern Swift; no Unmanaged hop.
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let locked = dict["CGSSessionScreenIsLocked"] as? Bool
        else { return false }
        return locked
    }
}

final class CaffeinateObserver: RefCountedObserver {
    static let shared = CaffeinateObserver()
    private override init() { super.init() }

    // State the observer maintains across notifications. Read by Caffeinate.snapshot()
    // when Bridge needs to push the channel.
    fileprivate var sleepingFlag: Bool = false
    fileprivate var lockedFlag: Bool = false

    override func install() -> Token {
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()

        // Seed lock state once; sleep starts false (we only observe transitions).
        lockedFlag = Caffeinate.currentlyLocked()
        sleepingFlag = false

        let t1 = ws.addObserver(forName: NSWorkspace.willSleepNotification,
                                object: nil, queue: .main) { [weak self] _ in
            self?.sleepingFlag = true
            self?.fire()
        }
        let t2 = ws.addObserver(forName: NSWorkspace.didWakeNotification,
                                object: nil, queue: .main) { [weak self] _ in
            self?.sleepingFlag = false
            self?.fire()
        }
        // The screensaver and lock-screen notifications come from
        // DistributedNotificationCenter, not the workspace center — they're
        // posted by loginwindow, not NSWorkspace. Same shape Hammerspoon uses
        // for hs.caffeinate.watcher's lockScreen / unlockScreen events.
        let t3 = dn.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                object: nil, queue: .main) { [weak self] _ in
            self?.lockedFlag = true
            self?.fire()
        }
        let t4 = dn.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                object: nil, queue: .main) { [weak self] _ in
            self?.lockedFlag = false
            self?.fire()
        }

        return Token {
            ws.removeObserver(t1)
            ws.removeObserver(t2)
            dn.removeObserver(t3)
            dn.removeObserver(t4)
        }
    }
}
