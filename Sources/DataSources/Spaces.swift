import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// =====================================================================
// MARK: - Spaces
// =====================================================================

// Per-display Spaces info via SkyLight private SPI. Same family of symbols
// hs.spaces uses (SLSCopyManagedDisplaySpaces, SLSSpaceGetType). Shared
// SkyLight loader lives in Sources/Private/SkyLight.swift; this enum just
// declares the symbol surface this domain needs.
private enum SkyLightSpaces {
    typealias CopyManagedSpacesFn    = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias SpaceGetTypeFn         = @convention(c) (Int32, UInt64) -> Int32
    typealias CopySpacesForWindowsFn = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?

    // uint64 SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef displayIdent)
    // — signature per Hammerspoon's hs.spaces. Takes the raw "Display
    // Identifier" string from the managed-displays snapshot (the literal
    // "Main" included) and returns the space id live from the window server,
    // where the snapshot's embedded "Current Space" can lag mid-switch.
    typealias DisplayGetCurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64

    // SLSRegisterConnectionNotifyProc(cid, callback, eventType, context). Used
    // for kCGSEvent space-life notifs that NSWorkspace doesn't surface. Yabai's
    // src/yabai.c is the reference for the exact signature.
    typealias CGSConnectionCallback = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
    typealias RegisterNotifyProcFn  = @convention(c) (Int32, CGSConnectionCallback, UInt32, UnsafeMutableRawPointer?) -> Int32

    // Write side (hs.spaces.moveWindowToSpace parity). Signatures per
    // yabai/src/misc/extern.h and Hammerspoon's hs.spaces implementation:
    //   void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef wids, uint64 sid)
    //   CGError SLSSpaceSetCompatID(int cid, uint64 sid, int workspace)
    //   CGError SLSSetWindowListWorkspace(int cid, uint32 *wids, int count, int workspace)
    typealias MoveWindowsToManagedSpaceFn = @convention(c) (Int32, CFArray, UInt64) -> Void
    typealias SpaceSetCompatIDFn          = @convention(c) (Int32, UInt64, Int32) -> Int32
    typealias SetWindowListWorkspaceFn    = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, Int32) -> Int32

    static let copyManagedSpaces:    CopyManagedSpacesFn?    = SkyLight.sym("SLSCopyManagedDisplaySpaces")
    static let spaceGetType:         SpaceGetTypeFn?         = SkyLight.sym("SLSSpaceGetType")
    static let displayGetCurrentSpace: DisplayGetCurrentSpaceFn? = SkyLight.sym("SLSManagedDisplayGetCurrentSpace")
    static let copySpacesForWindows: CopySpacesForWindowsFn? = SkyLight.sym("SLSCopySpacesForWindows")
    static let registerNotifyProc:   RegisterNotifyProcFn?   = SkyLight.sym("SLSRegisterConnectionNotifyProc")
    static let moveWindowsToManagedSpace: MoveWindowsToManagedSpaceFn? = SkyLight.sym("SLSMoveWindowsToManagedSpace")
    static let spaceSetCompatID:          SpaceSetCompatIDFn?          = SkyLight.sym("SLSSpaceSetCompatID")
    static let setWindowListWorkspace:    SetWindowListWorkspaceFn?    = SkyLight.sym("SLSSetWindowListWorkspace")
}

enum Spaces {
    /// Per-screen spaces info, keyed by NSScreen UUID:
    ///   { uuid: { displayID: int|undefined, spaces: [id, ...],
    ///            active: id|null, isFullscreen: bool } }
    /// displayID is the CGDirectDisplayID for the screen — pairs with the
    /// `display.id` field on sd.windows.focused (L2) and sd.mouse (R5.3),
    /// so consumers route by display id directly instead of joining UUIDs.
    static func all() -> [String: Any] {
        guard let copy = SkyLightSpaces.copyManagedSpaces,
              let getType = SkyLightSpaces.spaceGetType else {
            return [:]
        }
        let cid = SkyLight.cid
        guard let cfRef = copy(cid)?.takeRetainedValue() else { return [:] }
        let displays = cfRef as? [[String: Any]] ?? []

        // SkyLight identifies displays by either a UUID string or "Main" when
        // the "Displays Have Separate Spaces" preference is off. We rebuild a
        // UUID-keyed dict so the JS side is uniform regardless of that pref.
        let mainScreenUUID = NSScreen.screens.first.flatMap { screenUUID(for: $0) }

        // Per-screen displayID lookup so each entry can carry the CG display
        // id alongside the UUID key. Stacks routing by sd.windows.focused.
        // display.id (L2 enrichment) avoid a join against sd.display.all to
        // get the screen's identity — they index sd.spaces.all entries by
        // matching displayID directly.
        var displayIDByUUID: [String: Int] = [:]
        for screen in NSScreen.screens {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            if let uuid = screenUUID(for: screen), id != 0 {
                displayIDByUUID[uuid] = Int(id)
            }
        }

        return entries(
            displays: displays,
            mainScreenUUID: mainScreenUUID,
            displayIDByUUID: displayIDByUUID,
            currentSpace: { ident in
                SkyLightSpaces.displayGetCurrentSpace.map { $0(cid, ident as CFString) }
            },
            spaceType: { sid in getType(cid, sid) }
        )
    }

    /// Pure mapping from the SLSCopyManagedDisplaySpaces displays array to
    /// the per-UUID payload. `currentSpace` is queried with the RAW display
    /// identifier (before the "Main" remap — that's what the SLS call takes)
    /// and wins over the snapshot's embedded "Current Space" when it returns
    /// a nonzero id; the embedded value is the fallback for a missing symbol
    /// or a zero result.
    static func entries(displays: [[String: Any]],
                        mainScreenUUID: String?,
                        displayIDByUUID: [String: Int],
                        currentSpace: (String) -> UInt64?,
                        spaceType: (UInt64) -> Int32?) -> [String: Any] {
        var out: [String: Any] = [:]
        for disp in displays {
            let rawIdent = (disp["Display Identifier"] as? String) ?? ""
            var ident = rawIdent
            if ident == "Main", let main = mainScreenUUID { ident = main }
            let spacesArr = (disp["Spaces"] as? [[String: Any]]) ?? []

            var ids: [UInt64] = []
            for sp in spacesArr {
                if let n = sp["ManagedSpaceID"] as? NSNumber {
                    ids.append(n.uint64Value)
                }
            }
            var active = currentSpace(rawIdent).flatMap { $0 == 0 ? nil : $0 }
            if active == nil {
                let embedded = (disp["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber
                active = embedded?.uint64Value
            }

            // SLSSpaceGetType: 0 = user, 4 = fullscreen/tiled. Mirror hs.spaces.
            var isFullscreen = false
            if let a = active {
                isFullscreen = spaceType(a) == 4
            }

            var entry: [String: Any] = [
                "spaces":       ids.map { NSNumber(value: $0) },
                "active":       active.map { NSNumber(value: $0) } as Any? ?? NSNull(),
                "isFullscreen": isFullscreen
            ]
            if let did = displayIDByUUID[ident] { entry["displayID"] = did }
            out[ident] = entry
        }
        return out
    }

    private static func screenUUID(for screen: NSScreen) -> String? {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cf) as String?
    }

    /// Spaces the given window appears on, by CGWindowID. Backed by
    /// SLSCopySpacesForWindows (private SPI). Hammerspoon exposes this as
    /// hs.spaces.windowSpaces — tilers need it to know which space a window
    /// belongs to without trusting NSScreen-derived heuristics.
    static func windowSpaces(windowID: UInt32) -> [UInt64] {
        guard let fn = SkyLightSpaces.copySpacesForWindows else { return [] }
        let cid = SkyLight.cid
        // 0x7 covers all space-set masks (current, others, fullscreen, etc.)
        let arr: CFArray = [NSNumber(value: windowID)] as CFArray
        guard let cfRef = fn(cid, 0x7, arr)?.takeRetainedValue() else { return [] }
        let nums = (cfRef as? [NSNumber]) ?? []
        return nums.map { $0.uint64Value }
    }

    /// CGWindowIDs of all currently MINIMIZED windows on `spaceID`. Used by
    /// WindowScape's "where did I minimize this?" recall, and by future
    /// snapshot/restore code.
    ///
    /// Path chosen: CGWindowList(.optionAll) → filter `kCGWindowIsOnscreen == 0`
    /// → cross-reference each candidate with `windowSpaces(windowID:)`.
    /// SLSCopyWindowsWithOptionsAndTags is the more direct SLS route (yabai
    /// uses it with options=0x7 for "include minimized") but its set_tags /
    /// clear_tags out-parameter pair is easy to get wrong from Swift and the
    /// minimized bit isn't directly selectable — you'd still need a second
    /// pass against options=0x2 to subtract on-screen windows. The CG +
    /// windowSpaces route stays on public API for the heavy lift and only
    /// uses SLS for the per-window space lookup we already vend.
    static func minimizedWindows(spaceID: UInt64) -> [UInt32] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) else { return [] }
        let list = raw as! [[String: Any]]
        var out: [UInt32] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, Windows.isAppWindowLevel(layer),
                  let num = info[kCGWindowNumber as String] as? Int else { continue }
            let onscreen = (info[kCGWindowIsOnscreen as String] as? Int) ?? 0
            if onscreen != 0 { continue }
            let wid = UInt32(num)
            if windowSpaces(windowID: wid).contains(spaceID) {
                out.append(wid)
            }
        }
        return out
    }

    /// Move a window to another user space — hs.spaces.moveWindowToSpace
    /// parity. Fullscreen/tiled target spaces (SLSSpaceGetType == 4) are refused,
    /// mirroring hs.spaces.
    ///
    /// Two routes, each verified via windowSpaces (the same SLS query
    /// sd.spaces.forWindow vends), because SLSMoveWindowsToManagedSpace
    /// silently stopped moving other-process windows on macOS 14.5:
    ///  A. SLSMoveWindowsToManagedSpace — the direct call.
    ///  B. yabai's workaround: tag the target space with a compat ID,
    ///     SLSSetWindowListWorkspace the window onto that workspace tag,
    ///     clear the tag.
    /// Returns { ok, spaces } where spaces is the VERIFIED post-move space
    /// list — callers update their caches from it instead of polling for
    /// convergence. ok=false leaves the window wherever it was.
    static func moveWindow(windowID: UInt32, toSpace spaceID: UInt64) -> [String: Any] {
        let cid = SkyLight.cid
        func payload(_ ok: Bool) -> [String: Any] {
            ["ok": ok,
             "spaces": windowSpaces(windowID: windowID).map { NSNumber(value: $0) }]
        }
        guard windowID != 0, spaceID != 0 else { return payload(false) }
        if let getType = SkyLightSpaces.spaceGetType, getType(cid, spaceID) == 4 {
            return payload(false)
        }
        func landed() -> Bool { windowSpaces(windowID: windowID).contains(spaceID) }
        if landed() { return payload(true) }

        if let move = SkyLightSpaces.moveWindowsToManagedSpace {
            move(cid, [NSNumber(value: windowID)] as CFArray, spaceID)
            if landed() { notifySpacesChanged(); return payload(true) }
        }
        if let setCompat = SkyLightSpaces.spaceSetCompatID,
           let setWorkspace = SkyLightSpaces.setWindowListWorkspace {
            // yabai's magic workspace tag ("yabe" in ASCII). Any nonzero
            // value works; matching yabai's keeps the two tools from
            // littering the space with distinct compat IDs.
            let compatTag: Int32 = 0x7961_6265
            _ = setCompat(cid, spaceID, compatTag)
            var wid = windowID
            _ = setWorkspace(cid, &wid, 1, compatTag)
            _ = setCompat(cid, spaceID, 0)
            if landed() { notifySpacesChanged(); return payload(true) }
        }
        return payload(false)
    }

    private static func notifySpacesChanged() {
        WindowServerIntake.post(.spaces)
    }
}

// CGS event types observed below. Yabai's src/yabai.c is the reference for
// which IDs are live on shipping macOS:
//   1327 — space created
//   1328 — space destroyed
//   1401 — space switched (fires AFTER the window server commits the change,
//          unlike NSWorkspace's activeSpaceDidChange which can arrive while
//          the managed-displays snapshot still holds the old space)
//   1204 — Mission Control entered (proxy for the user-driven space re-order
//          interaction that NSWorkspace's activeSpaceDidChange doesn't fire on
//          when no active-space change happens)
//
// The registration is deliberately process-lifetime — SLSRemoveConnectionNotifyProc
// exists (OmniWM binds it) but there's nothing worth tearing down. We guard
// registration with a static flag and route into the singleton; Token cancel
// only tears down the NSWorkspace / NSApplication observers (the CGS callback
// no-ops once SpacesObserver has no subscribers because fire() iterates an
// empty subs dict).
private let kCGSEventSpaceCreated:        UInt32 = 1327
private let kCGSEventSpaceDestroyed:      UInt32 = 1328
private let kCGSEventSpaceDidChange:      UInt32 = 1401
private let kCGSEventMissionControlEnter: UInt32 = 1204

private let spacesCGSCallback: SkyLightSpaces.CGSConnectionCallback = { eventType, _, _, _, _ in
    // A space switch posts several of these at once; the intake merges them
    // into one spaces pass per drain.
    WindowServerIntake.post(.spaces)
    // 1204 is the only CGS signal for "Mission Control entered" — exit is
    // an AX notification on the Dock, handled in MissionControl.swift.
    if eventType == kCGSEventMissionControlEnter {
        WindowServerIntake.post(.missionControlEntered)
    }
}

final class SpacesObserver: RefCountedObserver {
    static let shared = SpacesObserver()
    private override init() { super.init() }

    private static var cgsRegistered = false

    override func install() -> Token {
        // Screen reconfig can add/remove displays, which changes the keys —
        // observe alongside activeSpaceDidChange. Both go through the
        // intake so a switch's 1401 + activeSpaceDidChange + 1325s cost
        // one spaces pass per drain.
        let post: (Notification) -> Void = { _ in WindowServerIntake.post(.spaces) }
        let ncToken = installNotifications([
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification, post),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, post)
        ])

        if !SpacesObserver.cgsRegistered,
           let reg = SkyLightSpaces.registerNotifyProc {
            let cid = SkyLight.cid
            _ = reg(cid, spacesCGSCallback, kCGSEventSpaceCreated,        nil)
            _ = reg(cid, spacesCGSCallback, kCGSEventSpaceDestroyed,      nil)
            _ = reg(cid, spacesCGSCallback, kCGSEventSpaceDidChange,      nil)
            _ = reg(cid, spacesCGSCallback, kCGSEventMissionControlEnter, nil)
            SpacesObserver.cgsRegistered = true
        }

        return ncToken
    }
}
