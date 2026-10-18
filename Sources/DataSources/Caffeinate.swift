import AppKit
import Foundation
import IOKit.pwr_mgt

// MARK: - Caffeinate (sleep + screen-lock state)

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

    // MARK: - Assertions (setter side of caffeinate)

    /// Holds a power-management assertion until release() is called. Three JS
    /// types map to three IOPM assertion strings:
    ///   - "display"      → kIOPMAssertionTypeNoDisplaySleep
    ///       (keeps the display awake while the assertion is held; user idle
    ///        timer doesn't dim or sleep the screen)
    ///   - "system"       → kIOPMAssertionTypeNoIdleSleep
    ///       (system stays awake even when user is idle; display may still
    ///        sleep on its own timer)
    ///   - "userActivity" → kIOPMAssertionTypePreventUserIdleSystemSleep
    ///       (advisory equivalent — same intent as "system" but bound to the
    ///        user-idle path; respects external power policy)
    /// Returns the raw IOPMAssertionID on success, nil on failure. Bridge
    /// owns the lifetime — assertions are released at stack unload via the
    /// scope drain, or explicitly via Caffeinate.release(id:).
    static func assert(type: String, reason: String) -> IOPMAssertionID? {
        let assertionType: CFString
        switch type {
        case "display":      assertionType = kIOPMAssertionTypeNoDisplaySleep as CFString
        case "system":       assertionType = kIOPMAssertionTypeNoIdleSleep as CFString
        case "userActivity": assertionType = kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        default:
            log("caffeinate.assert — unknown type \(type)")
            return nil
        }
        // Reason string is surfaced in `pmset -g assertions` / Activity Monitor,
        // so stacks should pass something descriptive. Empty falls back to a
        // generic label so the entry isn't anonymous.
        let label = reason.isEmpty ? "stackd assertion" : reason
        var assertionId: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            label as CFString,
            &assertionId
        )
        guard result == kIOReturnSuccess else {
            log("caffeinate.assert — IOPMAssertionCreateWithName failed (\(result))")
            return nil
        }
        return assertionId
    }

    /// Releases an assertion minted by `assert(type:reason:)`. Safe to call
    /// with a stale id — IOPMAssertionRelease returns an error code which we
    /// swallow (the alternative is leaking the slot, since callers have no
    /// useful recovery). No-op on kIOPMNullAssertionID.
    @discardableResult
    static func release(id: IOPMAssertionID) -> Bool {
        guard id != IOPMAssertionID(kIOPMNullAssertionID) else { return false }
        return IOPMAssertionRelease(id) == kIOReturnSuccess
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

        // The screensaver and lock-screen notifications come from
        // DistributedNotificationCenter, not the workspace center — they're
        // posted by loginwindow, not NSWorkspace. Same shape Hammerspoon uses
        // for hs.caffeinate.watcher's lockScreen / unlockScreen events.
        return installNotifications([
            (ws, NSWorkspace.willSleepNotification, { [weak self] _ in
                self?.sleepingFlag = true
                self?.fire()
            }),
            (ws, NSWorkspace.didWakeNotification, { [weak self] _ in
                self?.sleepingFlag = false
                self?.fire()
            }),
            (dn, Notification.Name("com.apple.screenIsLocked"), { [weak self] _ in
                self?.lockedFlag = true
                self?.fire()
            }),
            (dn, Notification.Name("com.apple.screenIsUnlocked"), { [weak self] _ in
                self?.lockedFlag = false
                self?.fire()
            })
        ])
    }
}
